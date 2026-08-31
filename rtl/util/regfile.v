`timescale 1ns/1ps
`include "util/reg_bank.v"

// Banked register file.  The low address bits select a bank and the remaining
// bits select a register within that bank.  Requesters must hold req, address,
// and write data stable until the corresponding valid output is asserted.

module cmn_reg_file #(
    parameter integer REG_WIDTH       = 64,
    parameter integer REG_COUNT       = 32,
    parameter integer READ_PORTS      = 2,
    parameter integer WRITE_PORTS     = 1,
    parameter integer BANK_SIZE       = 16,
    parameter integer NUM_BANKS       = (REG_COUNT / BANK_SIZE),
    parameter integer BANK_REG_BITS   = $clog2(BANK_SIZE),
    parameter integer BANK_SEL_BITS   = $clog2(NUM_BANKS),
    parameter integer ADDR_WIDTH      = BANK_SEL_BITS + BANK_REG_BITS,
    parameter integer READ_PORT_BITS  =
        (READ_PORTS > 1) ? $clog2(READ_PORTS) : 1,
    parameter integer WRITE_PORT_BITS =
        (WRITE_PORTS > 1) ? $clog2(WRITE_PORTS) : 1,
    parameter integer FPGA_LUTRAM = 0
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire [READ_PORTS-1:0][ADDR_WIDTH-1:0] rp_addr_i,
    output wire [READ_PORTS-1:0][REG_WIDTH-1:0]  rp_data_o,
    input  wire [READ_PORTS-1:0]                 rp_req_i,
    output wire [READ_PORTS-1:0]                 rp_valid_o,

    input  wire [WRITE_PORTS-1:0][ADDR_WIDTH-1:0] wp_addr_i,
    input  wire [WRITE_PORTS-1:0][REG_WIDTH-1:0]  wp_data_i,
    input  wire [WRITE_PORTS-1:0]                 wp_req_i,
    output wire [WRITE_PORTS-1:0]                 wp_valid_o,

    // True when no accepted transaction remains inside the file.  A caller's
    // complete busy predicate is (|req_i) || !quiescent_o: req_i covers work
    // still being presented, while this output covers accepted work.
    output wire                                   quiescent_o
);

    wire [REG_WIDTH-1:0] bank_read_data [NUM_BANKS-1:0];
    reg [BANK_REG_BITS-1:0] bank_read_sel [NUM_BANKS-1:0];
    reg bank_read_req [NUM_BANKS-1:0];

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
                .READ_PORTS(1),
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

    reg [READ_PORT_BITS-1:0] read_priority_q;
    reg [WRITE_PORT_BITS-1:0] write_priority_q;
    reg [READ_PORTS-1:0] read_grant;
    reg [WRITE_PORTS-1:0] write_grant;
    reg [READ_PORTS-1:0] read_valid_q;
    reg [WRITE_PORTS-1:0] write_valid_q;
    reg [BANK_SEL_BITS-1:0] read_response_bank_q [READ_PORTS-1:0];
    reg [READ_PORTS-1:0] read_bypass;
    reg [REG_WIDTH-1:0] read_bypass_data [READ_PORTS-1:0];
    reg [READ_PORTS-1:0] read_bypass_q;
    reg [REG_WIDTH-1:0] read_bypass_data_q [READ_PORTS-1:0];

    assign quiescent_o = !(|read_valid_q) && !(|write_valid_q);

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
    integer read_scan;
    reg [READ_PORT_BITS-1:0] read_candidate;
    reg [BANK_SEL_BITS-1:0] selected_read_bank;
    always @* begin
        read_grant = {READ_PORTS{1'b0}};
        read_candidate = 0;
        selected_read_bank = {BANK_SEL_BITS{1'b0}};

        for (clear_read_bank = 0; clear_read_bank < NUM_BANKS;
             clear_read_bank = clear_read_bank + 1) begin
            bank_read_sel[clear_read_bank] = {BANK_REG_BITS{1'b0}};
            bank_read_req[clear_read_bank] = 1'b0;
        end

        for (read_scan = 0; read_scan < READ_PORTS;
             read_scan = read_scan + 1) begin
            read_candidate = READ_PORT_BITS'(wrapped_index(
                32'(read_priority_q), read_scan, READ_PORTS));

            if (rst_n && rp_req_i[read_candidate] &&
                !read_valid_q[read_candidate]) begin
                selected_read_bank = read_port_addr[read_candidate]
                    [BANK_SEL_BITS-1:0];
                if (!bank_read_req[selected_read_bank]) begin
                    bank_read_req[selected_read_bank] = 1'b1;
                    bank_read_sel[selected_read_bank] =
                        read_port_addr[read_candidate]
                            [ADDR_WIDTH-1:BANK_SEL_BITS];
                    read_grant[read_candidate] = 1'b1;
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
            write_candidate = WRITE_PORT_BITS'(wrapped_index(
                32'(write_priority_q), write_scan, WRITE_PORTS));

            if (rst_n && wp_req_i[write_candidate] &&
                !write_valid_q[write_candidate]) begin
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

    genvar response_read_port;
    genvar response_write_port;
    generate
        for (response_read_port = 0; response_read_port < READ_PORTS;
             response_read_port = response_read_port + 1) begin : g_read_response
            assign rp_valid_o[response_read_port] =
                read_valid_q[response_read_port];
            assign rp_data_o[response_read_port] =
                read_valid_q[response_read_port] ?
                (read_bypass_q[response_read_port] ?
                 read_bypass_data_q[response_read_port] :
                 bank_read_data[
                    read_response_bank_q[response_read_port]]) :
                {REG_WIDTH{1'b0}};
        end

        for (response_write_port = 0; response_write_port < WRITE_PORTS;
             response_write_port = response_write_port + 1) begin : g_write_response
            assign wp_valid_o[response_write_port] =
                write_valid_q[response_write_port];
        end
    endgenerate

    integer state_read_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_priority_q <= {READ_PORT_BITS{1'b0}};
            write_priority_q <= {WRITE_PORT_BITS{1'b0}};
            read_valid_q <= {READ_PORTS{1'b0}};
            write_valid_q <= {WRITE_PORTS{1'b0}};
            read_bypass_q <= {READ_PORTS{1'b0}};

            for (state_read_port = 0;
                 state_read_port < READ_PORTS;
                 state_read_port = state_read_port + 1) begin
                read_response_bank_q[state_read_port] <=
                    {BANK_SEL_BITS{1'b0}};
                read_bypass_data_q[state_read_port] <=
                    {REG_WIDTH{1'b0}};
            end
        end else begin
            read_valid_q <= read_grant;
            write_valid_q <= write_grant;
            read_bypass_q <= read_bypass;

            for (state_read_port = 0;
                 state_read_port < READ_PORTS;
                 state_read_port = state_read_port + 1) begin
                if (read_grant[state_read_port]) begin
                    read_response_bank_q[state_read_port] <=
                        read_port_addr[state_read_port][BANK_SEL_BITS-1:0];
                    read_bypass_data_q[state_read_port] <=
                        read_bypass_data[state_read_port];
                end
            end

            if (|read_grant) begin
                read_priority_q <= READ_PORT_BITS'(wrapped_index(
                    32'(read_priority_q), 1, READ_PORTS));
            end

            if (|write_grant) begin
                write_priority_q <= WRITE_PORT_BITS'(wrapped_index(
                    32'(write_priority_q), 1, WRITE_PORTS));
            end
        end
    end

`ifndef SYNTHESIS
    // Stable hierarchy-visible view used by core-level simulation and trace
    // code. Address zero is omitted so element zero represents physical p1,
    // matching the existing PRF debug-vector convention.
    wire [REG_WIDTH-1:0] regs [1:REG_COUNT-1];
    wire [(REG_COUNT-1)*REG_WIDTH-1:0] prf_debug_regs;
    genvar debug_reg;
    generate
        for (debug_reg = 1; debug_reg < REG_COUNT;
             debug_reg = debug_reg + 1) begin : g_debug_reg
            localparam integer DEBUG_BANK = debug_reg % NUM_BANKS;
            localparam integer DEBUG_ROW = debug_reg / NUM_BANKS;

            assign regs[debug_reg] =
                g_banks[DEBUG_BANK].bank.read_lines[DEBUG_ROW];
            assign prf_debug_regs[
                (debug_reg-1)*REG_WIDTH +: REG_WIDTH] = regs[debug_reg];
        end
    endgenerate

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
