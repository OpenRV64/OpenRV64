`timescale 1ns/1ps
`include "util/reg_bank.v"

// Banked register file.  The low address bits select a bank and the remaining
// bits select a register within that bank.  Ack is the address-phase grant.
// Requesters hold req, address, and write data stable until ack, and may
// present the next transaction on the following cycle.  Read data and valid
// return one cycle after the corresponding read ack.

module cmn_reg_file #(
    parameter integer REG_WIDTH       = 64,
    parameter integer REG_COUNT       = 32,
    parameter integer READ_PORTS      = 2,
    parameter integer WRITE_PORTS     = 1,
    parameter integer READ_PORTS_PER_BANK = 1,
    // When set, lower-numbered write ports win same-bank conflicts.  This is
    // used by age-ordered retirement interfaces where port zero is oldest.
    // Otherwise conflicts retain round-robin fairness.
    parameter integer FIXED_WRITE_PRIORITY = 0,
    // Consecutive logical ports in a group are granted atomically.  A value
    // of one preserves ordinary per-port arbitration.  The 3P GPR uses pairs
    // so an instruction never consumes only one of its two source reads.
    parameter integer READ_GROUP_SIZE = 1,
    parameter integer BANK_SIZE       = 16,
    parameter integer NUM_BANKS       = (REG_COUNT / BANK_SIZE),
    parameter integer BANK_REG_BITS   = $clog2(BANK_SIZE),
    parameter integer BANK_SEL_BITS   = $clog2(NUM_BANKS),
    parameter integer ADDR_WIDTH      = BANK_SEL_BITS + BANK_REG_BITS,
    parameter integer READ_PORT_BITS  =
        (READ_PORTS > 1) ? $clog2(READ_PORTS) : 1,
    parameter integer READ_GROUP_COUNT = READ_PORTS / READ_GROUP_SIZE,
    parameter integer READ_GROUP_BITS =
        (READ_GROUP_COUNT > 1) ? $clog2(READ_GROUP_COUNT) : 1,
    parameter integer WRITE_PORT_BITS =
        (WRITE_PORTS > 1) ? $clog2(WRITE_PORTS) : 1,
    parameter integer READ_SLOT_BITS =
        (READ_PORTS_PER_BANK > 1) ? $clog2(READ_PORTS_PER_BANK) : 1,
    parameter integer FPGA_LUTRAM = 0
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire [READ_PORTS-1:0][ADDR_WIDTH-1:0] rp_addr_i,
    output wire [READ_PORTS-1:0][REG_WIDTH-1:0]  rp_data_o,
    input  wire [READ_PORTS-1:0]                 rp_req_i,
    output wire [READ_PORTS-1:0]                 rp_ack_o,
    output wire [READ_PORTS-1:0]                 rp_valid_o,

    input  wire [WRITE_PORTS-1:0][ADDR_WIDTH-1:0] wp_addr_i,
    input  wire [WRITE_PORTS-1:0][REG_WIDTH-1:0]  wp_data_i,
    input  wire [WRITE_PORTS-1:0]                 wp_req_i,
    output wire [WRITE_PORTS-1:0]                 wp_ack_o,
    output wire [WRITE_PORTS-1:0]                 wp_valid_o,

    // True when no accepted transaction remains inside the file.  A caller's
    // complete busy predicate is (|req_i) || !quiescent_o: req_i covers work
    // still being presented, while this output covers accepted work.
    output wire                                   quiescent_o,

    // Combinational simulation/performance probes for atomic read grouping.
    // A partial opportunity is a denied group for which ordinary per-port
    // arbitration could accept at least one member at the exact point the
    // group was considered.  These signals do not affect arbitration.
    output reg [7:0]                              trace_read_group_denied_o,
    output reg [7:0]                              trace_read_group_partial_o,
    output reg [7:0]                              trace_read_early_accept_o
);

    wire [READ_PORTS_PER_BANK-1:0][REG_WIDTH-1:0]
        bank_read_data [NUM_BANKS-1:0];
    reg [READ_PORTS_PER_BANK-1:0][BANK_REG_BITS-1:0]
        bank_read_sel [NUM_BANKS-1:0];
    reg [READ_PORTS_PER_BANK-1:0]
        bank_read_req [NUM_BANKS-1:0];

    wire [ADDR_WIDTH-1:0] read_port_addr [READ_PORTS-1:0];
    wire [ADDR_WIDTH-1:0] write_port_addr [WRITE_PORTS-1:0];
    wire [REG_WIDTH-1:0] write_port_data [WRITE_PORTS-1:0];

    reg [REG_WIDTH-1:0] bank_write_data [NUM_BANKS-1:0];
    reg [BANK_REG_BITS-1:0] bank_write_sel [NUM_BANKS-1:0];
    reg bank_write_req [NUM_BANKS-1:0];

    genvar bank_id;
    genvar input_read_port;
    genvar input_write_port;
    generate
        for (input_read_port = 0; input_read_port < READ_PORTS;
             input_read_port = input_read_port + 1) begin : g_read_inputs
            assign read_port_addr[input_read_port] =
                rp_addr_i[input_read_port];
        end

        for (input_write_port = 0; input_write_port < WRITE_PORTS;
             input_write_port = input_write_port + 1) begin : g_write_inputs
            assign write_port_addr[input_write_port] =
                wp_addr_i[input_write_port];
            assign write_port_data[input_write_port] =
                wp_data_i[input_write_port];
        end

        for (bank_id = 0; bank_id < NUM_BANKS;
             bank_id = bank_id + 1) begin : g_banks
            cmn_reg_bank #(
                .REG_WIDTH(REG_WIDTH),
                .REG_NUM(BANK_SIZE),
                .READ_PORTS(READ_PORTS_PER_BANK),
                .WRITE_PORTS(1),
                .FPGA_LUTRAM(FPGA_LUTRAM)
            ) bank (
                .clk(clk),
                .read_val_o(bank_read_data[bank_id]),
                .read_sel_i(bank_read_sel[bank_id]),
                .read_req_i(bank_read_req[bank_id]),
                .write_val_i(bank_write_data[bank_id]),
                .write_sel_i(bank_write_sel[bank_id]),
                .write_req_i(bank_write_req[bank_id])
            );
        end
    endgenerate

    reg [READ_GROUP_BITS-1:0] read_priority_q;
    reg [WRITE_PORT_BITS-1:0] write_priority_q;
    reg [READ_PORTS-1:0] read_grant;
    reg [WRITE_PORTS-1:0] write_grant;
    reg [READ_PORTS-1:0] read_valid_q;
    reg [WRITE_PORTS-1:0] write_valid_q;
    reg [BANK_SEL_BITS-1:0] read_response_bank_q [READ_PORTS-1:0];
    reg [READ_SLOT_BITS-1:0] read_response_slot_q [READ_PORTS-1:0];
    reg [READ_SLOT_BITS-1:0] read_grant_slot [READ_PORTS-1:0];
    reg [READ_PORTS-1:0] read_bypass;
    reg [REG_WIDTH-1:0] read_bypass_data [READ_PORTS-1:0];
    reg [READ_PORTS-1:0] read_bypass_q;
    reg [REG_WIDTH-1:0] read_bypass_data_q [READ_PORTS-1:0];

`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
    // Experimental simulation upper bound: an accepted read has no data
    // phase, so only delayed writes can keep the file non-quiescent.
    assign quiescent_o = !(|write_valid_q);
`else
    assign quiescent_o = !(|read_valid_q) && !(|write_valid_q);
`endif

    function automatic integer wrapped_index;
        input integer start_index;
        input integer offset;
        input integer item_count;
        begin
            wrapped_index = start_index + offset;
            if (wrapped_index >= item_count)
                wrapped_index = wrapped_index - item_count;
        end
    endfunction

    integer clear_read_bank;
    integer clear_read_slot;
    integer clear_read_port;
    integer read_group_scan;
    integer read_group_member;
    integer read_group_bank;
    integer read_group_used [NUM_BANKS-1:0];
    integer read_group_need [NUM_BANKS-1:0];
    integer read_independent_used [NUM_BANKS-1:0];
    integer read_group_early_accept;
    integer read_slot;
    reg [READ_GROUP_BITS-1:0] read_group_candidate;
    reg [READ_PORT_BITS-1:0] read_group_port;
    reg [BANK_SEL_BITS-1:0] selected_read_bank;
    reg read_group_fits;
    reg read_slot_found;
    // SystemVerilog always_comb deliberately excludes variables written by
    // this block from its inferred sensitivity list.  The group-demand and
    // group-used arrays are procedural temporaries: including them (as @*
    // does in Icarus) can retrigger this block forever as each evaluation
    // clears and rebuilds the temporary counts.
    always_comb begin
        read_grant = {READ_PORTS{1'b0}};
        read_group_candidate = 0;
        read_group_port = 0;
        selected_read_bank = {BANK_SEL_BITS{1'b0}};
        read_group_fits = 1'b0;
        read_slot_found = 1'b0;
        trace_read_group_denied_o = 8'd0;
        trace_read_group_partial_o = 8'd0;
        trace_read_early_accept_o = 8'd0;
        read_group_early_accept = 0;

        for (clear_read_port = 0; clear_read_port < READ_PORTS;
             clear_read_port = clear_read_port + 1) begin
            read_grant_slot[clear_read_port] = {READ_SLOT_BITS{1'b0}};
        end

        for (clear_read_bank = 0; clear_read_bank < NUM_BANKS;
             clear_read_bank = clear_read_bank + 1) begin
            read_independent_used[clear_read_bank] = 0;
            for (clear_read_slot = 0;
                 clear_read_slot < READ_PORTS_PER_BANK;
                 clear_read_slot = clear_read_slot + 1) begin
                bank_read_sel[clear_read_bank][clear_read_slot] =
                    {BANK_REG_BITS{1'b0}};
                bank_read_req[clear_read_bank][clear_read_slot] = 1'b0;
            end
        end

        // Greedily admit complete requester groups in rotating group order.
        // First count the group's demand per bank against slots consumed by
        // older admitted groups, then assign physical slots only if every
        // requested member fits.  This prevents a denied second source from
        // leaving an instruction with a half-accepted address phase.
        for (read_group_scan = 0;
             read_group_scan < READ_GROUP_COUNT;
             read_group_scan = read_group_scan + 1) begin
            read_group_candidate = READ_GROUP_BITS'(wrapped_index(
                32'(read_priority_q), read_group_scan,
                READ_GROUP_COUNT));
            read_group_fits = rst_n;

            for (read_group_bank = 0;
                 read_group_bank < NUM_BANKS;
                 read_group_bank = read_group_bank + 1) begin
                read_group_used[read_group_bank] = 0;
                read_group_need[read_group_bank] = 0;
                for (read_slot = 0;
                     read_slot < READ_PORTS_PER_BANK;
                     read_slot = read_slot + 1) begin
                    if (bank_read_req[read_group_bank][read_slot])
                        read_group_used[read_group_bank] =
                            read_group_used[read_group_bank] + 1;
                end
            end

            for (read_group_member = 0;
                 read_group_member < READ_GROUP_SIZE;
                 read_group_member = read_group_member + 1) begin
                read_group_port = READ_PORT_BITS'(
                    read_group_candidate * READ_GROUP_SIZE +
                    read_group_member);
                if (rp_req_i[read_group_port]) begin
                    selected_read_bank = read_port_addr[read_group_port]
                        [BANK_SEL_BITS-1:0];
                    read_group_need[selected_read_bank] =
                        read_group_need[selected_read_bank] + 1;
                end
            end

            for (read_group_bank = 0;
                 read_group_bank < NUM_BANKS;
                 read_group_bank = read_group_bank + 1) begin
                if ((read_group_used[read_group_bank] +
                     read_group_need[read_group_bank]) >
                    READ_PORTS_PER_BANK)
                    read_group_fits = 1'b0;
            end

            // Measure the work suppressed solely by all-or-nothing group
            // admission.  Replay the denied group's members against the bank
            // slots already consumed by older admitted groups, but do not
            // alter the real grant state.  The requester would need retained
            // per-operand ownership to exploit these early accepts.
            if (!read_group_fits) begin
                trace_read_group_denied_o =
                    trace_read_group_denied_o + 1'b1;
                read_group_early_accept = 0;
                for (read_group_bank = 0;
                     read_group_bank < NUM_BANKS;
                     read_group_bank = read_group_bank + 1)
                    read_independent_used[read_group_bank] =
                        read_group_used[read_group_bank];

                for (read_group_member = 0;
                     read_group_member < READ_GROUP_SIZE;
                     read_group_member = read_group_member + 1) begin
                    read_group_port = READ_PORT_BITS'(
                        read_group_candidate * READ_GROUP_SIZE +
                        read_group_member);
                    if (rp_req_i[read_group_port]) begin
                        selected_read_bank = read_port_addr[read_group_port]
                            [BANK_SEL_BITS-1:0];
                        if (read_independent_used[selected_read_bank] <
                            READ_PORTS_PER_BANK) begin
                            read_independent_used[selected_read_bank] =
                                read_independent_used[selected_read_bank] + 1;
                            read_group_early_accept =
                                read_group_early_accept + 1;
                        end
                    end
                end
                if (read_group_early_accept != 0) begin
                    trace_read_group_partial_o =
                        trace_read_group_partial_o + 1'b1;
                    trace_read_early_accept_o =
                        trace_read_early_accept_o +
                        read_group_early_accept[7:0];
                end
            end

            if (read_group_fits) begin
                for (read_group_member = 0;
                     read_group_member < READ_GROUP_SIZE;
                     read_group_member = read_group_member + 1) begin
                    read_group_port = READ_PORT_BITS'(
                        read_group_candidate * READ_GROUP_SIZE +
                        read_group_member);
                    if (rp_req_i[read_group_port]) begin
                        selected_read_bank = read_port_addr[read_group_port]
                            [BANK_SEL_BITS-1:0];
                        read_slot_found = 1'b0;
                        for (read_slot = 0;
                             read_slot < READ_PORTS_PER_BANK;
                             read_slot = read_slot + 1) begin
                            if (!read_slot_found &&
                                !bank_read_req[selected_read_bank]
                                              [read_slot]) begin
                                bank_read_req[selected_read_bank]
                                             [read_slot] = 1'b1;
                                bank_read_sel[selected_read_bank][read_slot] =
                                    read_port_addr[read_group_port]
                                        [ADDR_WIDTH-1:BANK_SEL_BITS];
                                read_grant[read_group_port] = 1'b1;
                                read_grant_slot[read_group_port] =
                                    READ_SLOT_BITS'(read_slot);
                                read_slot_found = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    // The storage arrays are read-before-write at a shared clock edge.  When
    // independently granted read and write transactions name the same word,
    // carry the granted write value through the existing response latch.
    // At most one write per bank can be granted, so an address has at most one
    // bypass source in a cycle.
    integer bypass_read_port;
    integer bypass_write_port;
    always @* begin
        read_bypass = {READ_PORTS{1'b0}};
        for (bypass_read_port = 0;
             bypass_read_port < READ_PORTS;
             bypass_read_port = bypass_read_port + 1) begin
            read_bypass_data[bypass_read_port] = {REG_WIDTH{1'b0}};
            for (bypass_write_port = 0;
                 bypass_write_port < WRITE_PORTS;
                 bypass_write_port = bypass_write_port + 1) begin
                if (read_grant[bypass_read_port] &&
                    write_grant[bypass_write_port] &&
                    (read_port_addr[bypass_read_port] ==
                     write_port_addr[bypass_write_port])) begin
                    read_bypass[bypass_read_port] = 1'b1;
                    read_bypass_data[bypass_read_port] =
                        write_port_data[bypass_write_port];
                end
            end
        end
    end

    integer clear_write_bank;
    integer write_scan;
    reg [WRITE_PORT_BITS-1:0] write_candidate;
    reg [BANK_SEL_BITS-1:0] selected_write_bank;
    always @* begin
        write_grant = {WRITE_PORTS{1'b0}};
        write_candidate = 0;
        selected_write_bank = {BANK_SEL_BITS{1'b0}};

        for (clear_write_bank = 0; clear_write_bank < NUM_BANKS;
             clear_write_bank = clear_write_bank + 1) begin
            bank_write_data[clear_write_bank] = {REG_WIDTH{1'b0}};
            bank_write_sel[clear_write_bank] = {BANK_REG_BITS{1'b0}};
            bank_write_req[clear_write_bank] = 1'b0;
        end

        for (write_scan = 0; write_scan < WRITE_PORTS;
             write_scan = write_scan + 1) begin
            if (FIXED_WRITE_PRIORITY != 0)
                write_candidate = WRITE_PORT_BITS'(write_scan);
            else
                write_candidate = WRITE_PORT_BITS'(wrapped_index(
                    32'(write_priority_q), write_scan, WRITE_PORTS));

            if (rst_n && wp_req_i[write_candidate]) begin
                selected_write_bank = write_port_addr[write_candidate]
                    [BANK_SEL_BITS-1:0];
                if (!bank_write_req[selected_write_bank]) begin
                    bank_write_req[selected_write_bank] = 1'b1;
                    bank_write_sel[selected_write_bank] =
                        write_port_addr[write_candidate]
                            [ADDR_WIDTH-1:BANK_SEL_BITS];
                    bank_write_data[selected_write_bank] =
                        write_port_data[write_candidate];
                    write_grant[write_candidate] = 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Stable hierarchy-visible view used by core-level simulation and trace
    // code. Address zero is omitted so element zero represents physical p1,
    // matching the existing PRF debug-vector convention.  The magic-read
    // experiment also uses this view for an asynchronous same-cycle read.
    wire [REG_WIDTH-1:0] regs [1:REG_COUNT-1];
    wire [REG_WIDTH-1:0] magic_regs [0:REG_COUNT-1];
    wire [(REG_COUNT-1)*REG_WIDTH-1:0] prf_debug_regs;
    assign magic_regs[0] = {REG_WIDTH{1'b0}};
    genvar debug_reg;
    generate
        for (debug_reg = 1; debug_reg < REG_COUNT;
             debug_reg = debug_reg + 1) begin : g_debug_reg
            localparam integer DEBUG_BANK = debug_reg % NUM_BANKS;
            localparam integer DEBUG_ROW = debug_reg / NUM_BANKS;

            assign regs[debug_reg] =
                g_banks[DEBUG_BANK].bank.read_lines[DEBUG_ROW];
            assign magic_regs[debug_reg] = regs[debug_reg];
            assign prf_debug_regs[
                (debug_reg-1)*REG_WIDTH +: REG_WIDTH] = regs[debug_reg];
        end
    endgenerate
`endif

    genvar response_read_port;
    genvar response_write_port;
    generate
        for (response_read_port = 0; response_read_port < READ_PORTS;
             response_read_port = response_read_port + 1) begin : g_read_response
            assign rp_ack_o[response_read_port] =
                read_grant[response_read_port];
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
            assign rp_valid_o[response_read_port] =
                read_grant[response_read_port];
            assign rp_data_o[response_read_port] =
                read_grant[response_read_port] ?
                (read_bypass[response_read_port] ?
                 read_bypass_data[response_read_port] :
                 magic_regs[read_port_addr[response_read_port]]) :
                {REG_WIDTH{1'b0}};
`else
            assign rp_valid_o[response_read_port] =
                read_valid_q[response_read_port];
            assign rp_data_o[response_read_port] =
                read_valid_q[response_read_port] ?
                (read_bypass_q[response_read_port] ?
                 read_bypass_data_q[response_read_port] :
                 bank_read_data[
                    read_response_bank_q[response_read_port]][
                    read_response_slot_q[response_read_port]]) :
                {REG_WIDTH{1'b0}};
`endif
        end

        for (response_write_port = 0; response_write_port < WRITE_PORTS;
             response_write_port = response_write_port + 1) begin : g_write_response
            assign wp_ack_o[response_write_port] =
                write_grant[response_write_port];
            assign wp_valid_o[response_write_port] =
                write_valid_q[response_write_port];
        end
    endgenerate

    integer state_read_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_priority_q <= {READ_GROUP_BITS{1'b0}};
            write_priority_q <= {WRITE_PORT_BITS{1'b0}};
            read_valid_q <= {READ_PORTS{1'b0}};
            write_valid_q <= {WRITE_PORTS{1'b0}};
            read_bypass_q <= {READ_PORTS{1'b0}};

            for (state_read_port = 0;
                 state_read_port < READ_PORTS;
                 state_read_port = state_read_port + 1) begin
                read_response_bank_q[state_read_port] <=
                    {BANK_SEL_BITS{1'b0}};
                read_response_slot_q[state_read_port] <=
                    {READ_SLOT_BITS{1'b0}};
                read_bypass_data_q[state_read_port] <=
                    {REG_WIDTH{1'b0}};
            end
        end else begin
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
            read_valid_q <= {READ_PORTS{1'b0}};
            read_bypass_q <= {READ_PORTS{1'b0}};
`else
            read_valid_q <= read_grant;
            read_bypass_q <= read_bypass;
`endif
            write_valid_q <= write_grant;

            for (state_read_port = 0;
                 state_read_port < READ_PORTS;
                 state_read_port = state_read_port + 1) begin
                if (read_grant[state_read_port]) begin
                    read_response_bank_q[state_read_port] <=
                        read_port_addr[state_read_port][BANK_SEL_BITS-1:0];
                    read_response_slot_q[state_read_port] <=
                        read_grant_slot[state_read_port];
                    read_bypass_data_q[state_read_port] <=
                        read_bypass_data[state_read_port];
                end
            end

            if (|read_grant) begin
                read_priority_q <= READ_GROUP_BITS'(wrapped_index(
                    32'(read_priority_q), 1, READ_GROUP_COUNT));
            end

            if (|write_grant) begin
                write_priority_q <= WRITE_PORT_BITS'(wrapped_index(
                    32'(write_priority_q), 1, WRITE_PORTS));
            end
        end
    end

`ifndef SYNTHESIS
    integer hazard_read_port;
    integer hazard_write_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hazard_read_port = 0;
            hazard_write_port = 0;
        end else begin
            for (hazard_read_port = 0;
                 hazard_read_port < READ_PORTS;
                 hazard_read_port = hazard_read_port + 1) begin
                for (hazard_write_port = 0;
                     hazard_write_port < WRITE_PORTS;
                     hazard_write_port = hazard_write_port + 1) begin
                    if (read_grant[hazard_read_port] &&
                        write_grant[hazard_write_port] &&
                        (read_port_addr[hazard_read_port] ==
                         write_port_addr[hazard_write_port]) &&
                        !read_bypass[hazard_read_port])
                        $fatal(1,
                               "cmn_reg_file: same-address read/write was not bypassed");
                end
            end
        end
    end

    initial begin
        if (READ_PORTS < 1)
            $fatal(1, "cmn_reg_file: READ_PORTS must be at least one.");
        if (WRITE_PORTS < 1)
            $fatal(1, "cmn_reg_file: WRITE_PORTS must be at least one.");
        if ((READ_PORTS_PER_BANK < 1) ||
            (READ_PORTS_PER_BANK > READ_PORTS))
            $fatal(1,
                   "cmn_reg_file: invalid physical read ports per bank.");
        if ((READ_GROUP_SIZE < 1) ||
            (READ_GROUP_SIZE > READ_PORTS) ||
            ((READ_PORTS % READ_GROUP_SIZE) != 0))
            $fatal(1, "cmn_reg_file: invalid atomic read group size.");
        if (NUM_BANKS < 2)
            $fatal(1, "cmn_reg_file: NUM_BANKS must be at least two.");
        if (BANK_SIZE < 2)
            $fatal(1, "cmn_reg_file: BANK_SIZE must be at least two.");
        if (REG_COUNT != NUM_BANKS * BANK_SIZE)
            $fatal(1, "cmn_reg_file: banks must exactly cover REG_COUNT.");
        if ((NUM_BANKS & (NUM_BANKS - 1)) != 0)
            $fatal(1, "cmn_reg_file: NUM_BANKS must be a power of two.");
        if ((BANK_SIZE & (BANK_SIZE - 1)) != 0)
            $fatal(1, "cmn_reg_file: BANK_SIZE must be a power of two.");
    end
`endif

endmodule
