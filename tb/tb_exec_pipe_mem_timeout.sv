`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/lsu-defs.v"

module tb_exec_pipe_mem_timeout;

    localparam integer RETIRE_SLOT_WIDTH = 3;
    localparam integer ISSUE_WIDTH =
        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer I_PRIV = 2;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_LSU_OP = 22;
    localparam integer I_IMM = 40;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;

    reg clk;
    reg rst_n;
    reg issue_valid;
    wire issue_ready;
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_payload;
    wire complete_valid;
    wire mem_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag;
    wire mem_resp_ready;

    openrv64_exec_pipe_mem #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .LSU_DEPTH(2),
        .LSU_TIMEOUT_CYCLES(4),
        .ENABLE_POSTED_STORES(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(1'b0),
        .issue_valid_i(issue_valid),
        .issue_ready_o(issue_ready),
        .issue_id_i(`OPENRV64_INSTR_ID_WIDTH'(7)),
        .issue_slot_i(RETIRE_SLOT_WIDTH'(3)),
        .issue_payload_i(issue_payload),
        .ordered_head_valid_i(1'b0),
        .ordered_head_id_i(
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .ordered_head_slot_i({RETIRE_SLOT_WIDTH{1'b0}}),
        .complete_valid_o(complete_valid),
        .complete_ready_i(1'b1),
        .complete_id_o(),
        .complete_slot_o(),
        .complete_payload_o(),
        .async_store_fault_o(),
        .async_store_page_fault_o(),
        .async_store_fault_pc_o(),
        .async_store_fault_addr_o(),
        .async_store_fault_trace_o(),
        .async_store_fault_instr_o(),
        .posted_store_pending_o(),
        .mem_valid_o(mem_valid),
        .mem_ready_i(1'b1),
        .mem_tag_o(mem_tag),
        .mem_resp_valid_i(1'b0),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(
            {`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .mem_error_i(1'b0),
        .mem_page_fault_i(1'b0),
        .mem_access_allowed_i(1'b1),
        .mem_lock_o(),
        .mem_write_o(),
        .mem_addr_o(),
        .mem_wdata_o(),
        .mem_wstrb_o(),
        .mem_access_o(),
        .mem_effective_addr_o(),
        .mem_size_o(),
        .pending_head_valid_o(),
        .pending_head_id_o(),
        .pending_head_ordered_o(),
        .queue_busy_o(),
        .forward_store_valid_i(1'b0),
        .forward_store_addr_i({`RV64_XLEN{1'b0}}),
        .forward_store_wdata_i({`RV64_XLEN{1'b0}}),
        .forward_store_wstrb_i(8'h00),
        .forward_store_valid_o(),
        .forward_store_addr_o(),
        .forward_store_wdata_o(),
        .forward_store_wstrb_o(),
        .mem_rdata_i({`RV64_XLEN{1'b0}})
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        issue_valid = 1'b0;
        issue_payload = {ISSUE_WIDTH{1'b0}};
        issue_payload[I_PRIV +: `RV64_PRIV_WIDTH] = `RV64_PRIV_M;
        issue_payload[I_MEM_READ] = 1'b1;
        issue_payload[I_REG_WRITE] = 1'b1;
        issue_payload[I_LSU_OP +: `RV64_LSU_OP_WIDTH] =
            `RV64_LSU_OP_LD;
        issue_payload[I_RS1_DATA +: `RV64_XLEN] = 64'h4000;
        issue_payload[I_IMM +: `RV64_XLEN] = 64'd0;
        issue_payload[I_INSTR +: `RV64_INSTR_WIDTH] =
            32'h0000_b103;
        issue_payload[I_PC +: `RV64_XLEN] = 64'h8000_0100;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        issue_valid = 1'b1;
        @(posedge clk);
        issue_valid = 1'b0;

        repeat (12) @(posedge clk);
        $fatal(1, "LSU timeout assertion did not fire");
    end

    wire unused_outputs = |{
        issue_ready, complete_valid, mem_valid, mem_tag, mem_resp_ready
    };

endmodule
