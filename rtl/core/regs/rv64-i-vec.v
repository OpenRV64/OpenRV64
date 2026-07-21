`timescale 1ns/1ps

// Private vector register file physically split by architectural register
// parity.  Every port moves one SLICE_WIDTH chunk; LMUL affects address
// sequencing in the execution units and never widens this interface.
//
// Each parity bank accepts at most two reads and one write per cycle.  The
// four logical read and two logical write ports expose bank conflicts through
// ready, allowing future multiplier, accumulator, and LSU clients to arbitrate
// without constructing MAX_LMUL*VLEN-wide muxes.
module openrv64_rv64i_vec #(
    parameter integer VLEN = 256,
    parameter integer SLICE_WIDTH = 64,
    parameter integer NUM_REGS = 32,
    parameter integer REG_ADDR_WIDTH = 5,
    parameter integer SLICE_ADDR_WIDTH =
        ((VLEN / SLICE_WIDTH) <= 1) ? 1 : $clog2(VLEN / SLICE_WIDTH),
    parameter integer RESET_REGS = 1,
    parameter integer READ_WRITE_BYPASS = 1
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire [3:0]                        read_valid_i,
    output wire [3:0]                        read_ready_o,
    input  wire [4*REG_ADDR_WIDTH-1:0]       read_addr_i,
    input  wire [4*SLICE_ADDR_WIDTH-1:0]     read_slice_i,
    output wire [4*SLICE_WIDTH-1:0]          read_data_o,

    input  wire [1:0]                        write_valid_i,
    output wire [1:0]                        write_ready_o,
    input  wire [2*REG_ADDR_WIDTH-1:0]       write_addr_i,
    input  wire [2*SLICE_ADDR_WIDTH-1:0]     write_slice_i,
    input  wire [2*SLICE_WIDTH-1:0]          write_data_i
);

    localparam integer NUM_SLICES = VLEN / SLICE_WIDTH;
    localparam integer BANK_ROWS = NUM_REGS / 2;

    reg [SLICE_WIDTH-1:0] even_bank [0:BANK_ROWS-1][0:NUM_SLICES-1];
    reg [SLICE_WIDTH-1:0] odd_bank [0:BANK_ROWS-1][0:NUM_SLICES-1];

    wire [REG_ADDR_WIDTH-1:0] read_addr0 =
        read_addr_i[0*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
    wire [REG_ADDR_WIDTH-1:0] read_addr1 =
        read_addr_i[1*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
    wire [REG_ADDR_WIDTH-1:0] read_addr2 =
        read_addr_i[2*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
    wire [REG_ADDR_WIDTH-1:0] read_addr3 =
        read_addr_i[3*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];

    // Ports zero and one fit in a two-read bank even when they collide.  Later
    // ports are admitted only while fewer than two earlier accepted requests
    // target the same parity bank.
    assign read_ready_o[0] = 1'b1;
    assign read_ready_o[1] = 1'b1;
    assign read_ready_o[2] = !(
        read_valid_i[0] && read_valid_i[1] &&
        (read_addr0[0] == read_addr2[0]) &&
        (read_addr1[0] == read_addr2[0]));
    wire read2_fire = read_valid_i[2] && read_ready_o[2];
    wire [1:0] read3_prior_count =
        (read_valid_i[0] && (read_addr0[0] == read_addr3[0])) +
        (read_valid_i[1] && (read_addr1[0] == read_addr3[0])) +
        (read2_fire && (read_addr2[0] == read_addr3[0]));
    assign read_ready_o[3] = read3_prior_count < 2;

    wire [REG_ADDR_WIDTH-1:0] write_addr0 =
        write_addr_i[0*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
    wire [REG_ADDR_WIDTH-1:0] write_addr1 =
        write_addr_i[1*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
    assign write_ready_o[0] = 1'b1;
    assign write_ready_o[1] = !(write_valid_i[0] &&
                                (write_addr0[0] == write_addr1[0]));
    wire write0_fire = write_valid_i[0] && write_ready_o[0];
    wire write1_fire = write_valid_i[1] && write_ready_o[1];

    genvar read_port;
    generate
        for (read_port = 0; read_port < 4;
             read_port = read_port + 1) begin : g_read
            wire [REG_ADDR_WIDTH-1:0] read_addr =
                read_addr_i[read_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
            wire [SLICE_ADDR_WIDTH-1:0] read_slice =
                read_slice_i[read_port*SLICE_ADDR_WIDTH +:
                             SLICE_ADDR_WIDTH];
            wire [REG_ADDR_WIDTH-2:0] read_row =
                read_addr[REG_ADDR_WIDTH-1:1];
            wire [SLICE_WIDTH-1:0] bank_data = read_addr[0] ?
                odd_bank[read_row][read_slice] :
                even_bank[read_row][read_slice];
            wire bypass0 = (READ_WRITE_BYPASS != 0) && write0_fire &&
                (write_addr0 == read_addr) &&
                (write_slice_i[0*SLICE_ADDR_WIDTH +: SLICE_ADDR_WIDTH] ==
                 read_slice);
            wire bypass1 = (READ_WRITE_BYPASS != 0) && write1_fire &&
                (write_addr1 == read_addr) &&
                (write_slice_i[1*SLICE_ADDR_WIDTH +: SLICE_ADDR_WIDTH] ==
                 read_slice);

            assign read_data_o[read_port*SLICE_WIDTH +: SLICE_WIDTH] =
                bypass1 ? write_data_i[1*SLICE_WIDTH +: SLICE_WIDTH] :
                bypass0 ? write_data_i[0*SLICE_WIDTH +: SLICE_WIDTH] :
                bank_data;
        end
    endgenerate

    integer row_index;
    integer slice_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (RESET_REGS != 0) begin
                for (row_index = 0; row_index < BANK_ROWS;
                     row_index = row_index + 1) begin
                    for (slice_index = 0; slice_index < NUM_SLICES;
                         slice_index = slice_index + 1) begin
                        even_bank[row_index][slice_index] <=
                            {SLICE_WIDTH{1'b0}};
                        odd_bank[row_index][slice_index] <=
                            {SLICE_WIDTH{1'b0}};
                    end
                end
            end
        end else begin
            if (write0_fire) begin
                if (write_addr0[0])
                    odd_bank[write_addr0[REG_ADDR_WIDTH-1:1]]
                            [write_slice_i[0*SLICE_ADDR_WIDTH +:
                                           SLICE_ADDR_WIDTH]] <=
                        write_data_i[0*SLICE_WIDTH +: SLICE_WIDTH];
                else
                    even_bank[write_addr0[REG_ADDR_WIDTH-1:1]]
                             [write_slice_i[0*SLICE_ADDR_WIDTH +:
                                            SLICE_ADDR_WIDTH]] <=
                        write_data_i[0*SLICE_WIDTH +: SLICE_WIDTH];
            end
            if (write1_fire) begin
                if (write_addr1[0])
                    odd_bank[write_addr1[REG_ADDR_WIDTH-1:1]]
                            [write_slice_i[1*SLICE_ADDR_WIDTH +:
                                           SLICE_ADDR_WIDTH]] <=
                        write_data_i[1*SLICE_WIDTH +: SLICE_WIDTH];
                else
                    even_bank[write_addr1[REG_ADDR_WIDTH-1:1]]
                             [write_slice_i[1*SLICE_ADDR_WIDTH +:
                                            SLICE_ADDR_WIDTH]] <=
                        write_data_i[1*SLICE_WIDTH +: SLICE_WIDTH];
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((VLEN <= 0) || ((VLEN % SLICE_WIDTH) != 0))
            $fatal(1, "VLEN must be a positive multiple of SLICE_WIDTH");
        if (SLICE_WIDTH != 64)
            $fatal(1, "initial banked vector register file uses 64-bit slices");
        if ((NUM_REGS < 2) || ((NUM_REGS % 2) != 0))
            $fatal(1, "vector register count must split evenly into two banks");
        if ((1 << REG_ADDR_WIDTH) < NUM_REGS)
            $fatal(1, "vector register address width is too small");
    end
`endif

endmodule
