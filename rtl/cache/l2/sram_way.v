`timescale 1ns/1ps

// One L2 way: one synchronous read port and one full-width write port.
//
// Data and tags deliberately have no reset.  Valid metadata outside this
// module determines whether an entry is usable.  Keeping each memory in one
// clocked process preserves block-RAM/SRAM inference and avoids simulator-wide
// sensitivity to every cache line.
module openrv64_l2_sram_way #(
    parameter integer SETS = 512,
    parameter integer SET_INDEX_WIDTH = $clog2(SETS),
    parameter integer DATA_WIDTH = 512,
    parameter integer TAG_WIDTH = 49
) (
    input  wire                       clk_i,
    input  wire                       read_enable_i,
    input  wire [SET_INDEX_WIDTH-1:0] read_set_i,
    output wire [DATA_WIDTH-1:0]      read_data_o,
    output wire [TAG_WIDTH-1:0]       read_tag_o,
    input  wire                       write_enable_i,
    input  wire [SET_INDEX_WIDTH-1:0] write_set_i,
    input  wire [DATA_WIDTH-1:0]      write_data_i,
    input  wire                       write_tag_i,
    input  wire [TAG_WIDTH-1:0]       write_tag_data_i
);

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [DATA_WIDTH-1:0] data_mem [0:SETS-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [TAG_WIDTH-1:0] tag_mem [0:SETS-1];

    reg [DATA_WIDTH-1:0] read_data_q;
    reg [TAG_WIDTH-1:0] read_tag_q;
    reg data_bypass_q;
    reg tag_bypass_q;
    reg [DATA_WIDTH-1:0] bypass_data_q;
    reg [TAG_WIDTH-1:0] bypass_tag_q;

    assign read_data_o = data_bypass_q ? bypass_data_q : read_data_q;
    assign read_tag_o = tag_bypass_q ? bypass_tag_q : read_tag_q;

    always @(posedge clk_i) begin
        if (read_enable_i) begin
            read_data_q <= data_mem[read_set_i];
            read_tag_q <= tag_mem[read_set_i];
            data_bypass_q <= write_enable_i &&
                             (write_set_i == read_set_i);
            tag_bypass_q <= write_enable_i && write_tag_i &&
                            (write_set_i == read_set_i);
            bypass_data_q <= write_data_i;
            bypass_tag_q <= write_tag_data_i;
        end

        if (write_enable_i) begin
            data_mem[write_set_i] <= write_data_i;
            if (write_tag_i)
                tag_mem[write_set_i] <= write_tag_data_i;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((SETS < 1) || ((SETS & (SETS - 1)) != 0))
            $fatal(1, "L2 SRAM-way set count must be a power of two");
        if ((DATA_WIDTH < 8) || ((DATA_WIDTH & 7) != 0))
            $fatal(1, "L2 SRAM-way data width must contain whole bytes");
        if (TAG_WIDTH < 1)
            $fatal(1, "L2 SRAM-way tag width must be positive");
    end
`endif

endmodule
