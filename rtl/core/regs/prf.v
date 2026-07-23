`ifndef OPENRV64_PRF_V
`define OPENRV64_PRF_V

`timescale 1ns/1ps

// Parameterized physical register file storage.
//
// Logical register N maps to bank (N % NUM_BANKS), row
// (N / NUM_BANKS).  Each register may contain one or more independently
// addressed slices.  Ports are considered in ascending order; an access is
// ready when the target bank still has capacity after all earlier accepted
// accesses.  Consequently, higher-numbered write ports win an allowed
// duplicate write and same-cycle bypass.  Read data is meaningful only when
// the corresponding read_valid_i and read_ready_o bits are both asserted;
// writes take effect only on the analogous valid/ready handshake.
//
// This module intentionally contains storage and bank arbitration only.  An
// architectural register map, rename table, free list, and operand readiness
// tracking belong above it.
module openrv64_prf #(
    parameter integer DATA_WIDTH = 64,
    parameter integer NUM_REGS = 32,
    parameter integer REG_ADDR_WIDTH =
        (NUM_REGS <= 1) ? 1 : $clog2(NUM_REGS),
    parameter integer NUM_SLICES = 1,
    parameter integer SLICE_ADDR_WIDTH =
        (NUM_SLICES <= 1) ? 1 : $clog2(NUM_SLICES),
    parameter integer NUM_BANKS = 1,
    parameter integer READ_PORTS = 2,
    parameter integer WRITE_PORTS = 1,
    parameter integer READ_PORTS_PER_BANK = READ_PORTS,
    parameter integer WRITE_PORTS_PER_BANK = WRITE_PORTS,
    parameter integer ZERO_REG_ENABLE = 0,
    parameter integer ZERO_REG_INDEX = 0,
    parameter integer RESET_REGS = 1,
    parameter integer READ_WRITE_BYPASS = 1,
    parameter integer ALLOW_DUPLICATE_WRITES = 0
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    input  wire [READ_PORTS-1:0]                 read_valid_i,
    output reg  [READ_PORTS-1:0]                 read_ready_o,
    input  wire [READ_PORTS*REG_ADDR_WIDTH-1:0]  read_addr_i,
    input  wire [READ_PORTS*SLICE_ADDR_WIDTH-1:0] read_slice_i,
    output reg  [READ_PORTS*DATA_WIDTH-1:0]       read_data_o,

    input  wire [WRITE_PORTS-1:0]                write_valid_i,
    output reg  [WRITE_PORTS-1:0]                write_ready_o,
    input  wire [WRITE_PORTS*REG_ADDR_WIDTH-1:0] write_addr_i,
    input  wire [WRITE_PORTS*SLICE_ADDR_WIDTH-1:0] write_slice_i,
    input  wire [WRITE_PORTS*DATA_WIDTH-1:0]      write_data_i,

    // Flattened logical-register view for verification and compatibility
    // wrappers.  Slice zero occupies the least-significant DATA_WIDTH bits of
    // each register.
    output wire [NUM_REGS*NUM_SLICES*DATA_WIDTH-1:0] debug_regs_o
);

    localparam integer BANK_ROWS = NUM_REGS / NUM_BANKS;
    localparam integer BANK_DEPTH = BANK_ROWS * NUM_SLICES;
    localparam integer BANK_BITS = BANK_DEPTH * DATA_WIDTH;
    localparam integer REG_COMPARE_WIDTH = REG_ADDR_WIDTH + 1;
    localparam integer SLICE_COMPARE_WIDTH = SLICE_ADDR_WIDTH + 1;
    localparam integer BANK_SELECT_WIDTH =
        (NUM_BANKS <= 1) ? 1 : $clog2(NUM_BANKS);
    localparam integer READ_SLOT_WIDTH =
        (READ_PORTS_PER_BANK <= 1) ? 1 : $clog2(READ_PORTS_PER_BANK);
    localparam integer WRITE_SLOT_WIDTH =
        (WRITE_PORTS_PER_BANK <= 1) ? 1 : $clog2(WRITE_PORTS_PER_BANK);

    reg [BANK_SELECT_WIDTH-1:0] read_bank_select [0:READ_PORTS-1];
    reg [READ_SLOT_WIDTH-1:0] read_slot_select [0:READ_PORTS-1];
    reg [BANK_SELECT_WIDTH-1:0] write_bank_select [0:WRITE_PORTS-1];
    reg [WRITE_SLOT_WIDTH-1:0] write_slot_select [0:WRITE_PORTS-1];

    function automatic integer address_bank;
        input [REG_ADDR_WIDTH-1:0] address;
        integer address_value;
        begin
            address_value = integer'($unsigned(address));
            address_bank = address_value % NUM_BANKS;
        end
    endfunction

    function automatic integer address_row;
        input [REG_ADDR_WIDTH-1:0] address;
        integer address_value;
        begin
            address_value = integer'($unsigned(address));
            address_row = address_value / NUM_BANKS;
        end
    endfunction

    function automatic logic address_is_valid;
        input [REG_ADDR_WIDTH-1:0] address;
        begin
            address_is_valid = ({1'b0, address} <
                                REG_COMPARE_WIDTH'(NUM_REGS));
        end
    endfunction

    function automatic logic slice_is_valid;
        input [SLICE_ADDR_WIDTH-1:0] slice_address;
        begin
            slice_is_valid = ({1'b0, slice_address} <
                              SLICE_COMPARE_WIDTH'(NUM_SLICES));
        end
    endfunction

    function automatic logic address_uses_storage;
        input [REG_ADDR_WIDTH-1:0] address;
        begin
            address_uses_storage = address_is_valid(address) &&
                !((ZERO_REG_ENABLE != 0) &&
                  (address == REG_ADDR_WIDTH'(ZERO_REG_INDEX)));
        end
    endfunction

    integer write_port;
    integer prior_write_port;
    integer write_bank;
    integer prior_write_bank;
    integer write_bank_use;
    reg [REG_ADDR_WIDTH-1:0] write_address;
    reg [REG_ADDR_WIDTH-1:0] prior_write_address;

    always @* begin
        write_ready_o = {WRITE_PORTS{1'b1}};
        write_address = {REG_ADDR_WIDTH{1'b0}};
        prior_write_address = {REG_ADDR_WIDTH{1'b0}};
        write_bank = 0;
        prior_write_bank = 0;
        write_bank_use = 0;
        prior_write_port = 0;

        for (write_port = 0; write_port < WRITE_PORTS;
             write_port = write_port + 1) begin
            write_bank_select[write_port] =
                {BANK_SELECT_WIDTH{1'b0}};
            write_slot_select[write_port] =
                {WRITE_SLOT_WIDTH{1'b0}};
            write_address = write_addr_i[
                write_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
            if (address_uses_storage(write_address)) begin
                write_bank = address_bank(write_address);
                write_bank_select[write_port] =
                    BANK_SELECT_WIDTH'(write_bank);
                write_bank_use = 0;
                for (prior_write_port = 0;
                     prior_write_port < write_port;
                     prior_write_port = prior_write_port + 1) begin
                    prior_write_address = write_addr_i[
                        prior_write_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH];
                    if (write_valid_i[prior_write_port] &&
                        write_ready_o[prior_write_port] &&
                        address_uses_storage(prior_write_address)) begin
                        prior_write_bank =
                            address_bank(prior_write_address);
                        if (prior_write_bank == write_bank)
                            write_bank_use = write_bank_use + 1;
                    end
                end
                write_slot_select[write_port] =
                    WRITE_SLOT_WIDTH'(write_bank_use);
                if (write_bank_use >= WRITE_PORTS_PER_BANK)
                    write_ready_o[write_port] = 1'b0;
            end
        end
    end

    integer read_port;
    integer prior_read_port;
    integer read_bank;
    integer prior_read_bank;
    integer read_bank_use;
    reg [REG_ADDR_WIDTH-1:0] read_address;
    reg [REG_ADDR_WIDTH-1:0] prior_read_address;

    always @* begin
        read_ready_o = {READ_PORTS{1'b1}};
        read_address = {REG_ADDR_WIDTH{1'b0}};
        prior_read_address = {REG_ADDR_WIDTH{1'b0}};
        read_bank = 0;
        prior_read_bank = 0;
        read_bank_use = 0;
        prior_read_port = 0;

        for (read_port = 0; read_port < READ_PORTS;
             read_port = read_port + 1) begin
            read_bank_select[read_port] = {BANK_SELECT_WIDTH{1'b0}};
            read_slot_select[read_port] = {READ_SLOT_WIDTH{1'b0}};
            read_address = read_addr_i[
                read_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
            if (address_uses_storage(read_address)) begin
                read_bank = address_bank(read_address);
                read_bank_select[read_port] =
                    BANK_SELECT_WIDTH'(read_bank);
                read_bank_use = 0;
                for (prior_read_port = 0;
                     prior_read_port < read_port;
                     prior_read_port = prior_read_port + 1) begin
                    prior_read_address = read_addr_i[
                        prior_read_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH];
                    if (read_valid_i[prior_read_port] &&
                        read_ready_o[prior_read_port] &&
                        address_uses_storage(prior_read_address)) begin
                        prior_read_bank = address_bank(prior_read_address);
                        if (prior_read_bank == read_bank)
                            read_bank_use = read_bank_use + 1;
                    end
                end
                read_slot_select[read_port] =
                    READ_SLOT_WIDTH'(read_bank_use);
                if (read_bank_use >= READ_PORTS_PER_BANK)
                    read_ready_o[read_port] = 1'b0;
            end
        end
    end

    // Route accepted logical reads onto the bounded physical read slots of
    // each bank.  Keeping the bank index constant in this generate structure
    // is deliberate: it prevents a nominally banked file from synthesizing as
    // READ_PORTS copies of an all-bank read mux.
    reg [DATA_WIDTH-1:0] bank_read_data
        [0:NUM_BANKS-1][0:READ_PORTS_PER_BANK-1];

    genvar physical_read_bank;
    genvar physical_read_slot;
    generate
        for (physical_read_bank = 0; physical_read_bank < NUM_BANKS;
             physical_read_bank = physical_read_bank + 1) begin : g_read_bank
            for (physical_read_slot = 0;
                 physical_read_slot < READ_PORTS_PER_BANK;
                 physical_read_slot = physical_read_slot + 1) begin : g_slot
                integer route_read_port;
                always @* begin
                    bank_read_data[physical_read_bank]
                                  [physical_read_slot] =
                        {DATA_WIDTH{1'b0}};
                    for (route_read_port = 0;
                         route_read_port < READ_PORTS;
                         route_read_port = route_read_port + 1) begin
                        if (read_valid_i[route_read_port] &&
                            read_ready_o[route_read_port] &&
                            address_uses_storage(read_addr_i[
                                route_read_port*REG_ADDR_WIDTH +:
                                REG_ADDR_WIDTH]) &&
                            slice_is_valid(read_slice_i[
                                route_read_port*SLICE_ADDR_WIDTH +:
                                SLICE_ADDR_WIDTH]) &&
                            (read_bank_select[route_read_port] ==
                             BANK_SELECT_WIDTH'(physical_read_bank)) &&
                            (read_slot_select[route_read_port] ==
                             READ_SLOT_WIDTH'(physical_read_slot))) begin
                            bank_read_data[physical_read_bank]
                                          [physical_read_slot] =
                                g_storage_bank[physical_read_bank].bank_q[
                                      (address_row(read_addr_i[
                                           route_read_port*REG_ADDR_WIDTH +:
                                           REG_ADDR_WIDTH])*NUM_SLICES +
                                       read_slice_i[
                                           route_read_port*SLICE_ADDR_WIDTH +:
                                           SLICE_ADDR_WIDTH])*DATA_WIDTH +:
                                      DATA_WIDTH];
                        end
                    end
                end
            end
        end
    endgenerate

    integer data_read_port;
    integer bypass_write_port;
    always @* begin
        read_data_o = {READ_PORTS*DATA_WIDTH{1'b0}};
        bypass_write_port = 0;

        for (data_read_port = 0; data_read_port < READ_PORTS;
             data_read_port = data_read_port + 1) begin
            if (read_valid_i[data_read_port] &&
                read_ready_o[data_read_port] &&
                address_uses_storage(read_addr_i[
                    data_read_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH]) &&
                slice_is_valid(read_slice_i[
                    data_read_port*SLICE_ADDR_WIDTH +:
                    SLICE_ADDR_WIDTH])) begin
                read_data_o[data_read_port*DATA_WIDTH +: DATA_WIDTH] =
                    bank_read_data[read_bank_select[data_read_port]]
                                  [read_slot_select[data_read_port]];

                if (READ_WRITE_BYPASS != 0) begin
                    // Ascending assignment makes the highest accepted write
                    // port the winner for an allowed duplicate destination.
                    for (bypass_write_port = 0;
                         bypass_write_port < WRITE_PORTS;
                         bypass_write_port = bypass_write_port + 1) begin
                        if (write_valid_i[bypass_write_port] &&
                            write_ready_o[bypass_write_port] &&
                            address_uses_storage(write_addr_i[
                                bypass_write_port*REG_ADDR_WIDTH +:
                                REG_ADDR_WIDTH]) &&
                            slice_is_valid(write_slice_i[
                                bypass_write_port*SLICE_ADDR_WIDTH +:
                                SLICE_ADDR_WIDTH]) &&
                            (write_addr_i[
                                bypass_write_port*REG_ADDR_WIDTH +:
                                REG_ADDR_WIDTH] == read_addr_i[
                                data_read_port*REG_ADDR_WIDTH +:
                                REG_ADDR_WIDTH]) &&
                            (write_slice_i[
                                bypass_write_port*SLICE_ADDR_WIDTH +:
                                SLICE_ADDR_WIDTH] == read_slice_i[
                                data_read_port*SLICE_ADDR_WIDTH +:
                                SLICE_ADDR_WIDTH])) begin
                            read_data_o[
                                data_read_port*DATA_WIDTH +: DATA_WIDTH] =
                                write_data_i[
                                    bypass_write_port*DATA_WIDTH +:
                                    DATA_WIDTH];
                        end
                    end
                end
            end
        end
    end

    // Accepted writes are likewise routed to bounded physical write slots.
    reg bank_write_valid
        [0:NUM_BANKS-1][0:WRITE_PORTS_PER_BANK-1];
    reg [REG_ADDR_WIDTH-1:0] bank_write_addr
        [0:NUM_BANKS-1][0:WRITE_PORTS_PER_BANK-1];
    reg [SLICE_ADDR_WIDTH-1:0] bank_write_slice
        [0:NUM_BANKS-1][0:WRITE_PORTS_PER_BANK-1];
    reg [DATA_WIDTH-1:0] bank_write_data
        [0:NUM_BANKS-1][0:WRITE_PORTS_PER_BANK-1];

    genvar physical_write_bank;
    genvar physical_write_slot;
    generate
        for (physical_write_bank = 0; physical_write_bank < NUM_BANKS;
             physical_write_bank = physical_write_bank + 1) begin : g_write_bank
            for (physical_write_slot = 0;
                 physical_write_slot < WRITE_PORTS_PER_BANK;
                 physical_write_slot = physical_write_slot + 1) begin : g_slot
                integer route_write_port;
                always @* begin
                    bank_write_valid[physical_write_bank]
                                    [physical_write_slot] = 1'b0;
                    bank_write_addr[physical_write_bank]
                                   [physical_write_slot] =
                        {REG_ADDR_WIDTH{1'b0}};
                    bank_write_slice[physical_write_bank]
                                    [physical_write_slot] =
                        {SLICE_ADDR_WIDTH{1'b0}};
                    bank_write_data[physical_write_bank]
                                   [physical_write_slot] =
                        {DATA_WIDTH{1'b0}};
                    for (route_write_port = 0;
                         route_write_port < WRITE_PORTS;
                         route_write_port = route_write_port + 1) begin
                        if (write_valid_i[route_write_port] &&
                            write_ready_o[route_write_port] &&
                            address_uses_storage(write_addr_i[
                                route_write_port*REG_ADDR_WIDTH +:
                                REG_ADDR_WIDTH]) &&
                            slice_is_valid(write_slice_i[
                                route_write_port*SLICE_ADDR_WIDTH +:
                                SLICE_ADDR_WIDTH]) &&
                            (write_bank_select[route_write_port] ==
                             BANK_SELECT_WIDTH'(physical_write_bank)) &&
                            (write_slot_select[route_write_port] ==
                             WRITE_SLOT_WIDTH'(physical_write_slot))) begin
                            bank_write_valid[physical_write_bank]
                                            [physical_write_slot] = 1'b1;
                            bank_write_addr[physical_write_bank]
                                           [physical_write_slot] =
                                write_addr_i[
                                    route_write_port*REG_ADDR_WIDTH +:
                                    REG_ADDR_WIDTH];
                            bank_write_slice[physical_write_bank]
                                            [physical_write_slot] =
                                write_slice_i[
                                    route_write_port*SLICE_ADDR_WIDTH +:
                                    SLICE_ADDR_WIDTH];
                            bank_write_data[physical_write_bank]
                                           [physical_write_slot] =
                                write_data_i[
                                    route_write_port*DATA_WIDTH +:
                                    DATA_WIDTH];
                        end
                    end
                end
            end
        end
    endgenerate

    genvar storage_bank;
    generate
        for (storage_bank = 0; storage_bank < NUM_BANKS;
             storage_bank = storage_bank + 1) begin : g_storage_bank
            reg [BANK_BITS-1:0] bank_q;
            integer storage_write_slot;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    if (RESET_REGS != 0)
                        bank_q <= {BANK_BITS{1'b0}};
                end else begin
                    for (storage_write_slot = 0;
                         storage_write_slot < WRITE_PORTS_PER_BANK;
                         storage_write_slot = storage_write_slot + 1) begin
                        if (bank_write_valid[storage_bank]
                                                [storage_write_slot]) begin
                            bank_q[(address_row(
                                       bank_write_addr[storage_bank]
                                                      [storage_write_slot])*
                                       NUM_SLICES +
                                   bank_write_slice[storage_bank]
                                                   [storage_write_slot])*
                                   DATA_WIDTH +: DATA_WIDTH] <=
                                bank_write_data[storage_bank]
                                               [storage_write_slot];
                        end
                    end
                end
            end
        end
    endgenerate

    genvar debug_reg;
    genvar debug_slice;
    generate
        for (debug_reg = 0; debug_reg < NUM_REGS;
             debug_reg = debug_reg + 1) begin : g_debug_reg
            for (debug_slice = 0; debug_slice < NUM_SLICES;
                 debug_slice = debug_slice + 1) begin : g_debug_slice
                if ((ZERO_REG_ENABLE != 0) &&
                    (debug_reg == ZERO_REG_INDEX)) begin : g_zero
                    assign debug_regs_o[
                        (debug_reg*NUM_SLICES + debug_slice)*DATA_WIDTH +:
                        DATA_WIDTH] = {DATA_WIDTH{1'b0}};
                end else begin : g_storage
                    assign debug_regs_o[
                        (debug_reg*NUM_SLICES + debug_slice)*DATA_WIDTH +:
                        DATA_WIDTH] =
                        g_storage_bank[debug_reg % NUM_BANKS].bank_q[
                            ((debug_reg / NUM_BANKS)*NUM_SLICES +
                             debug_slice)*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    integer check_read_port;
    integer check_write_port;
    integer check_other_write_port;
    reg [REG_ADDR_WIDTH-1:0] check_write_address;
    reg [REG_ADDR_WIDTH-1:0] check_other_write_address;
    reg [SLICE_ADDR_WIDTH-1:0] check_write_slice;
    reg [SLICE_ADDR_WIDTH-1:0] check_other_write_slice;

    initial begin
        if (DATA_WIDTH <= 0)
            $fatal(1, "PRF DATA_WIDTH must be positive");
        if (NUM_REGS <= 0)
            $fatal(1, "PRF NUM_REGS must be positive");
        if ((NUM_BANKS <= 0) || ((NUM_REGS % NUM_BANKS) != 0))
            $fatal(1, "PRF register count must divide evenly into banks");
        if (NUM_SLICES <= 0)
            $fatal(1, "PRF NUM_SLICES must be positive");
        if ((READ_PORTS <= 0) || (WRITE_PORTS <= 0))
            $fatal(1, "PRF must have read and write ports");
        if ((READ_PORTS_PER_BANK <= 0) ||
            (WRITE_PORTS_PER_BANK <= 0))
            $fatal(1, "PRF per-bank port counts must be positive");
        if ((2 ** REG_ADDR_WIDTH) < NUM_REGS)
            $fatal(1, "PRF register address width is too small");
        if ((2 ** SLICE_ADDR_WIDTH) < NUM_SLICES)
            $fatal(1, "PRF slice address width is too small");
        if ((ZERO_REG_ENABLE != 0) &&
            ((ZERO_REG_INDEX < 0) || (ZERO_REG_INDEX >= NUM_REGS)))
            $fatal(1, "PRF zero register index is out of range");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            for (check_read_port = 0; check_read_port < READ_PORTS;
                 check_read_port = check_read_port + 1) begin
                if (read_valid_i[check_read_port] &&
                    (!address_is_valid(read_addr_i[
                        check_read_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH]) ||
                     !slice_is_valid(read_slice_i[
                        check_read_port*SLICE_ADDR_WIDTH +:
                        SLICE_ADDR_WIDTH]))) begin
                    $fatal(1, "PRF read address is out of range");
                end
            end

            for (check_write_port = 0;
                 check_write_port < WRITE_PORTS;
                 check_write_port = check_write_port + 1) begin
                check_write_address = write_addr_i[
                    check_write_port*REG_ADDR_WIDTH +:
                    REG_ADDR_WIDTH];
                check_write_slice = write_slice_i[
                    check_write_port*SLICE_ADDR_WIDTH +:
                    SLICE_ADDR_WIDTH];
                if (write_valid_i[check_write_port] &&
                    (!address_is_valid(check_write_address) ||
                     !slice_is_valid(check_write_slice))) begin
                    $fatal(1, "PRF write address is out of range");
                end

                for (check_other_write_port = 0;
                     check_other_write_port < check_write_port;
                     check_other_write_port = check_other_write_port + 1) begin
                    check_other_write_address = write_addr_i[
                        check_other_write_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH];
                    check_other_write_slice = write_slice_i[
                        check_other_write_port*SLICE_ADDR_WIDTH +:
                        SLICE_ADDR_WIDTH];
                    if ((ALLOW_DUPLICATE_WRITES == 0) &&
                        write_valid_i[check_write_port] &&
                        write_ready_o[check_write_port] &&
                        write_valid_i[check_other_write_port] &&
                        write_ready_o[check_other_write_port] &&
                        !((ZERO_REG_ENABLE != 0) &&
                          (check_write_address ==
                           REG_ADDR_WIDTH'(ZERO_REG_INDEX))) &&
                        !((ZERO_REG_ENABLE != 0) &&
                          (check_other_write_address ==
                           REG_ADDR_WIDTH'(ZERO_REG_INDEX))) &&
                        (check_write_address ==
                         check_other_write_address) &&
                        (check_write_slice == check_other_write_slice)) begin
                        $fatal(1, "PRF accepted duplicate writes");
                    end
                end
            end
        end
    end
`endif

endmodule

`endif
