`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/exec/vec/instr-defs.v"

module tb_openrv64_vec_test_top;

    localparam logic [63:0] RESET_VECTOR = 64'h100;
    localparam integer RESET_INSTR_INDEX = RESET_VECTOR >> 2;
    localparam integer MEM_WORDS = 256;
    localparam integer DATAPATH_WIDTH = 64;
    localparam integer MEM_TAG_WIDTH = 8;

    logic clk;
    logic rst_n;

    logic ifetch_valid;
    logic ifetch_ready;
    logic [63:0] ifetch_addr;
    logic [63:0] ifetch_rdata;
    logic ifetch_error;

    logic vec_mem_req_valid;
    logic vec_mem_req_ready;
    logic [MEM_TAG_WIDTH-1:0] vec_mem_req_tag;
    logic vec_mem_req_write;
    logic [63:0] vec_mem_req_addr;
    logic [DATAPATH_WIDTH-1:0] vec_mem_req_wdata;
    logic [(DATAPATH_WIDTH/8)-1:0] vec_mem_req_wstrb;
    logic vec_mem_resp_valid;
    logic vec_mem_resp_ready;
    logic [MEM_TAG_WIDTH-1:0] vec_mem_resp_tag;
    logic [DATAPATH_WIDTH-1:0] vec_mem_resp_rdata;
    logic vec_mem_resp_error;
    logic vec_mem_resp_retry;

    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic dbg_error;
    logic dbg_vec_busy;
    logic dbg_vec_replay;
    logic [63:0] dbg_retired;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic response_valid_q;
    logic [MEM_TAG_WIDTH-1:0] response_tag_q;
    logic [63:0] response_data_q;
    logic response_error_q;
    logic response_retry_q;
    logic retry_used_q;
    integer fetch_count_q;
    integer vec_request_count_q;
    integer primary_request_count_q;
    integer read_request_count_q;
    integer vec_replay_count_q;
    logic dual_lsu_overlap_q;
    logic vsync_stall_seen_q;
    logic alu_command_overlap_q;
    logic vsync_alu_stall_seen_q;

    wire ifetch_in_range = ifetch_addr[63:11] == 0;
    assign ifetch_ready = ifetch_valid;
    assign ifetch_rdata = ifetch_in_range ?
        memory[ifetch_addr[10:3]] : 64'd0;
    assign ifetch_error = ifetch_valid && !ifetch_in_range;

    assign vec_mem_req_ready = !response_valid_q || vec_mem_resp_ready;
    assign vec_mem_resp_valid = response_valid_q;
    assign vec_mem_resp_tag = response_tag_q;
    assign vec_mem_resp_rdata = response_data_q;
    assign vec_mem_resp_error = response_error_q;
    assign vec_mem_resp_retry = response_retry_q;

    openrv64_vec_test_top #(
        .RESET_VECTOR(RESET_VECTOR), .VLEN(256),
        .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .MEM_TAG_WIDTH(MEM_TAG_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ifetch_valid_o(ifetch_valid), .ifetch_ready_i(ifetch_ready),
        .ifetch_addr_o(ifetch_addr), .ifetch_rdata_i(ifetch_rdata),
        .ifetch_error_i(ifetch_error),
        .vec_mem_req_valid_o(vec_mem_req_valid),
        .vec_mem_req_ready_i(vec_mem_req_ready),
        .vec_mem_req_tag_o(vec_mem_req_tag),
        .vec_mem_req_write_o(vec_mem_req_write),
        .vec_mem_req_addr_o(vec_mem_req_addr),
        .vec_mem_req_wdata_o(vec_mem_req_wdata),
        .vec_mem_req_wstrb_o(vec_mem_req_wstrb),
        .vec_mem_resp_valid_i(vec_mem_resp_valid),
        .vec_mem_resp_ready_o(vec_mem_resp_ready),
        .vec_mem_resp_tag_i(vec_mem_resp_tag),
        .vec_mem_resp_rdata_i(vec_mem_resp_rdata),
        .vec_mem_resp_error_i(vec_mem_resp_error),
        .vec_mem_resp_retry_i(vec_mem_resp_retry),
        .dbg_pc_o(dbg_pc), .dbg_instr_o(dbg_instr),
        .dbg_halted_o(dbg_halted), .dbg_error_o(dbg_error),
        .dbg_vec_busy_o(dbg_vec_busy),
        .dbg_vec_replay_o(dbg_vec_replay),
        .dbg_retired_o(dbg_retired)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] enc_addi;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB, rd,
                        `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_bne;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [12:0] imm;
        begin
            enc_bne = {imm[12], imm[10:5], rs2, rs1,
                       `RV64_FUNCT3_BNE, imm[4:1], imm[11],
                       `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic logic [31:0] enc_vset;
        input logic [4:0] scalar_rs1;
        begin
            enc_vset = {7'd0, 5'd0, scalar_rs1,
                        `OPENRV64_VEC_INSTR_FUNCT3_VSET, 5'd0,
                        `OPENRV64_VEC_INSTR_OPCODE_ALU};
        end
    endfunction

    function automatic logic [31:0] enc_vec_alu;
        input logic [2:0] funct3;
        input logic [4:0] vd;
        input logic [4:0] vs1;
        input logic [4:0] vs2;
        begin
            enc_vec_alu = {7'd0, vs2, vs1, funct3, vd,
                           `OPENRV64_VEC_INSTR_OPCODE_ALU};
        end
    endfunction

    function automatic logic [31:0] enc_vsync;
        input logic [4:0] vreg;
        begin
            enc_vsync = {7'd0, 5'd0, vreg,
                         `OPENRV64_VEC_INSTR_FUNCT3_VSYNC, 5'd0,
                         `OPENRV64_VEC_INSTR_OPCODE_ALU};
        end
    endfunction

    function automatic logic [31:0] enc_vload;
        input logic [4:0] vd;
        input logic [4:0] scalar_rs1;
        begin
            enc_vload = {12'd0, scalar_rs1,
                         `OPENRV64_VEC_INSTR_FUNCT3_LOAD, vd,
                         `OPENRV64_VEC_INSTR_OPCODE_LSU};
        end
    endfunction

    function automatic logic [31:0] enc_vstore;
        input logic [4:0] vs3;
        input logic [4:0] scalar_rs1;
        begin
            enc_vstore = {7'd0, vs3, scalar_rs1,
                          `OPENRV64_VEC_INSTR_FUNCT3_STORE, 5'd0,
                          `OPENRV64_VEC_INSTR_OPCODE_LSU};
        end
    endfunction

    task automatic put_instr;
        input integer instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0])
                memory[instr_index >> 1][63:32] = instr;
            else
                memory[instr_index >> 1][31:0] = instr;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_valid_q <= 1'b0;
            response_tag_q <= {MEM_TAG_WIDTH{1'b0}};
            response_data_q <= 64'd0;
            response_error_q <= 1'b0;
            response_retry_q <= 1'b0;
            retry_used_q <= 1'b0;
            fetch_count_q <= 0;
            vec_request_count_q <= 0;
            primary_request_count_q <= 0;
            read_request_count_q <= 0;
            vec_replay_count_q <= 0;
            dual_lsu_overlap_q <= 1'b0;
            vsync_stall_seen_q <= 1'b0;
            alu_command_overlap_q <= 1'b0;
            vsync_alu_stall_seen_q <= 1'b0;
        end else begin
            if (ifetch_valid && ifetch_ready)
                fetch_count_q <= fetch_count_q + 1;
            if (dbg_vec_replay)
                vec_replay_count_q <= vec_replay_count_q + 1;
            if (dut.vec_lsu_busy && dut.vec_read_busy)
                dual_lsu_overlap_q <= 1'b1;
            if (dut.instr_is_vsync && dut.vsync_wait)
                vsync_stall_seen_q <= 1'b1;
            if (dut.u_vec_alu.used_count_q > 1)
                alu_command_overlap_q <= 1'b1;
            if (dut.instr_is_vsync && dut.vsync_wait &&
                ((dut.instr_rs1 == 5'd11) ||
                 (dut.instr_rs1 == 5'd12)))
                vsync_alu_stall_seen_q <= 1'b1;

            if (response_valid_q && vec_mem_resp_ready)
                response_valid_q <= 1'b0;

            if (vec_mem_req_valid && vec_mem_req_ready) begin
                vec_request_count_q <= vec_request_count_q + 1;
                if (vec_mem_req_tag[MEM_TAG_WIDTH-1]) begin
                    read_request_count_q <= read_request_count_q + 1;
                    if (vec_mem_req_write)
                        $fatal(1, "read-only vector LSU emitted a write");
                end else begin
                    primary_request_count_q <= primary_request_count_q + 1;
                end
                response_valid_q <= 1'b1;
                response_tag_q <= vec_mem_req_tag;
                response_data_q <= (vec_mem_req_addr[63:11] == 0) ?
                    memory[vec_mem_req_addr[10:3]] : 64'd0;
                response_error_q <= vec_mem_req_addr[63:11] != 0;
                response_retry_q <= !retry_used_q &&
                                    (vec_mem_req_addr == 64'h208);
                if (!retry_used_q && (vec_mem_req_addr == 64'h208))
                    retry_used_q <= 1'b1;

                if (vec_mem_req_write) begin
                    if (vec_mem_req_wstrb != 8'hff)
                        $fatal(1, "test-top vector store was not a full beat");
                    if (vec_mem_req_addr[63:11] != 0)
                        $fatal(1, "test-top vector store escaped memory");
                    memory[vec_mem_req_addr[10:3]] <= vec_mem_req_wdata;
                end
            end
        end
    end

    integer init_index;
    integer timeout;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("trace_vec_test_top")) begin
            if (ifetch_valid && ifetch_ready)
                $display("ifetch pc=%x instr=%x", ifetch_addr,
                         ifetch_addr[2] ? ifetch_rdata[63:32] :
                                           ifetch_rdata[31:0]);
            if (vec_mem_req_valid && vec_mem_req_ready)
                $display("vecmem %s addr=%x tag=%0d",
                         vec_mem_req_write ? "store" : "load",
                         vec_mem_req_addr, vec_mem_req_tag);
            if (dbg_vec_replay)
                $display("vec replay pc=%x", dbg_pc);
        end
    end

    initial begin
        for (init_index = 0; init_index < MEM_WORDS;
             init_index = init_index + 1)
            memory[init_index] = 64'd0;

        // Bitwise stream: load v2/v3, XOR them into v4, and store v4.
        put_instr(RESET_INSTR_INDEX + 0,
                  enc_addi(5'd1, 5'd0, 12'h200));
        put_instr(RESET_INSTR_INDEX + 1, enc_vset(5'd0));
        put_instr(RESET_INSTR_INDEX + 2, enc_vload(5'd2, 5'd1));
        put_instr(RESET_INSTR_INDEX + 3,
                  enc_addi(5'd1, 5'd0, 12'h220));
        put_instr(RESET_INSTR_INDEX + 4, enc_vload(5'd3, 5'd1));
        put_instr(RESET_INSTR_INDEX + 5, enc_vsync(5'd2));
        put_instr(RESET_INSTR_INDEX + 6, enc_vsync(5'd3));
        put_instr(RESET_INSTR_INDEX + 7,
                  enc_vec_alu(`OPENRV64_VEC_INSTR_FUNCT3_XOR,
                              5'd4, 5'd2, 5'd3));
        put_instr(RESET_INSTR_INDEX + 8,
                  enc_addi(5'd1, 5'd0, 12'h240));
        put_instr(RESET_INSTR_INDEX + 9, enc_vsync(5'd4));
        put_instr(RESET_INSTR_INDEX + 10, enc_vstore(5'd4, 5'd1));

        // FP32 stream: load two vectors, add them into v8, and store v8.
        put_instr(RESET_INSTR_INDEX + 11,
                  enc_addi(5'd3, 5'd0, 12'h010));
        put_instr(RESET_INSTR_INDEX + 12, enc_vset(5'd3));
        put_instr(RESET_INSTR_INDEX + 13,
                  enc_addi(5'd1, 5'd0, 12'h260));
        put_instr(RESET_INSTR_INDEX + 14, enc_vload(5'd6, 5'd1));
        put_instr(RESET_INSTR_INDEX + 15,
                  enc_addi(5'd1, 5'd0, 12'h280));
        put_instr(RESET_INSTR_INDEX + 16, enc_vload(5'd7, 5'd1));
        put_instr(RESET_INSTR_INDEX + 17, enc_vsync(5'd6));
        put_instr(RESET_INSTR_INDEX + 18, enc_vsync(5'd7));
        put_instr(RESET_INSTR_INDEX + 19,
                  enc_vec_alu(`OPENRV64_VEC_INSTR_FUNCT3_FADD,
                              5'd8, 5'd6, 5'd7));
        put_instr(RESET_INSTR_INDEX + 20,
                  enc_addi(5'd1, 5'd0, 12'h2a0));
        put_instr(RESET_INSTR_INDEX + 21, enc_vsync(5'd8));
        put_instr(RESET_INSTR_INDEX + 22, enc_vstore(5'd8, 5'd1));

        // A lone preferred-path load proves that VSYNC itself waits rather
        // than relying on the blocking primary LSU to cover the dependency.
        put_instr(RESET_INSTR_INDEX + 23,
                  enc_addi(5'd1, 5'd0, 12'h2c0));
        put_instr(RESET_INSTR_INDEX + 24, enc_vload(5'd10, 5'd1));
        put_instr(RESET_INSTR_INDEX + 25, enc_vsync(5'd10));
        put_instr(RESET_INSTR_INDEX + 26,
                  enc_addi(5'd1, 5'd0, 12'h2e0));
        put_instr(RESET_INSTR_INDEX + 27, enc_vstore(5'd10, 5'd1));

        // Back-to-back independent arithmetic commands must coexist in the
        // tagged execution queue. VSYNC then observes both ALU destinations,
        // rather than only the read-only LSU destination.
        put_instr(RESET_INSTR_INDEX + 28,
                  enc_vec_alu(`OPENRV64_VEC_INSTR_FUNCT3_FADD,
                              5'd11, 5'd6, 5'd7));
        put_instr(RESET_INSTR_INDEX + 29,
                  enc_vec_alu(`OPENRV64_VEC_INSTR_FUNCT3_FMUL,
                              5'd12, 5'd6, 5'd7));
        put_instr(RESET_INSTR_INDEX + 30, enc_vsync(5'd11));
        put_instr(RESET_INSTR_INDEX + 31, enc_vsync(5'd12));
        put_instr(RESET_INSTR_INDEX + 32,
                  enc_addi(5'd1, 5'd0, 12'h300));
        put_instr(RESET_INSTR_INDEX + 33, enc_vstore(5'd11, 5'd1));
        put_instr(RESET_INSTR_INDEX + 34,
                  enc_addi(5'd1, 5'd0, 12'h320));
        put_instr(RESET_INSTR_INDEX + 35, enc_vstore(5'd12, 5'd1));

        // Exercise the real scalar branch unit with a three-iteration loop.
        put_instr(RESET_INSTR_INDEX + 36,
                  enc_addi(5'd2, 5'd0, 12'd3));
        put_instr(RESET_INSTR_INDEX + 37,
                  enc_addi(5'd2, 5'd2, 12'hfff));
        put_instr(RESET_INSTR_INDEX + 38,
                  enc_bne(5'd2, 5'd0, 13'h1ffc));
        put_instr(RESET_INSTR_INDEX + 39, `RV64_INSTR_EBREAK);

        memory[64] = 64'h0123_4567_89ab_cdef;
        memory[65] = 64'h1111_2222_3333_4444;
        memory[66] = 64'hffff_0000_aaaa_5555;
        memory[67] = 64'h1357_9bdf_2468_ace0;
        memory[68] = 64'hffff_0000_ffff_0000;
        memory[69] = 64'h0101_0101_0101_0101;
        memory[70] = 64'h00ff_00ff_00ff_00ff;
        memory[71] = 64'hffff_ffff_0000_0000;

        memory[76] = 64'h3f80_0000_3f80_0000;
        memory[77] = 64'h3f80_0000_3f80_0000;
        memory[78] = 64'h3f80_0000_3f80_0000;
        memory[79] = 64'h3f80_0000_3f80_0000;
        memory[80] = 64'h4000_0000_4000_0000;
        memory[81] = 64'h4000_0000_4000_0000;
        memory[82] = 64'h4000_0000_4000_0000;
        memory[83] = 64'h4000_0000_4000_0000;
        memory[88] = 64'h0123_0123_0123_0123;
        memory[89] = 64'h4567_4567_4567_4567;
        memory[90] = 64'h89ab_89ab_89ab_89ab;
        memory[91] = 64'hcdef_cdef_cdef_cdef;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        timeout = 0;
        while (!dbg_halted && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(negedge clk);

        if (!dbg_halted || dbg_error)
            $fatal(1, "vector test top failed halt=%0b error=%0b pc=%x instr=%x",
                   dbg_halted, dbg_error, dbg_pc, dbg_instr);
        if (dbg_pc != 64'h19c || dbg_instr != `RV64_INSTR_EBREAK)
            $fatal(1, "vector test top halted at unexpected instruction");
        if (dbg_retired != 64'd43)
            $fatal(1, "vector test top retired %0d instructions, expected 43",
                   dbg_retired);

        if (memory[72] !== (memory[64] ^ memory[68]) ||
            memory[73] !== (memory[65] ^ memory[69]) ||
            memory[74] !== (memory[66] ^ memory[70]) ||
            memory[75] !== (memory[67] ^ memory[71]))
            $fatal(1, "instruction-stream vector XOR result mismatch");

        if ((memory[84] !== 64'h4040_0000_4040_0000) ||
            (memory[85] !== 64'h4040_0000_4040_0000) ||
            (memory[86] !== 64'h4040_0000_4040_0000) ||
            (memory[87] !== 64'h4040_0000_4040_0000))
            $fatal(1, "instruction-stream FP32 add result mismatch");

        if ((memory[92] !== memory[88]) ||
            (memory[93] !== memory[89]) ||
            (memory[94] !== memory[90]) ||
            (memory[95] !== memory[91]))
            $fatal(1, "VSYNC-protected preferred load result mismatch");

        if ((memory[96] !== 64'h4040_0000_4040_0000) ||
            (memory[97] !== 64'h4040_0000_4040_0000) ||
            (memory[98] !== 64'h4040_0000_4040_0000) ||
            (memory[99] !== 64'h4040_0000_4040_0000))
            $fatal(1, "overlapped FP32 add result mismatch");
        if ((memory[100] !== 64'h4000_0000_4000_0000) ||
            (memory[101] !== 64'h4000_0000_4000_0000) ||
            (memory[102] !== 64'h4000_0000_4000_0000) ||
            (memory[103] !== 64'h4000_0000_4000_0000))
            $fatal(1, "overlapped FP32 multiply result mismatch");

        if (!retry_used_q || (vec_replay_count_q == 0))
            $fatal(1, "instruction-stream LSU did not replay internally");
        if (!dual_lsu_overlap_q || (primary_request_count_q == 0) ||
            (read_request_count_q == 0))
            $fatal(1,
                   "dual LSU paths did not overlap primary=%0d read=%0d overlap=%0b",
                   primary_request_count_q, read_request_count_q,
                   dual_lsu_overlap_q);
        if (!vsync_stall_seen_q)
            $fatal(1, "VSYNC never blocked on a pending vector write");
        if (!alu_command_overlap_q)
            $fatal(1, "independent vector arithmetic commands did not overlap");
        if (!vsync_alu_stall_seen_q)
            $fatal(1, "VSYNC did not block on an arithmetic destination");
        if (dbg_vec_busy)
            $fatal(1, "vector unit remained busy after architectural halt");

        $display("PASS: dual-LSU scalar/vector instruction-stream test top");
        $display("      fetched=%0d retired=%0d vec_requests=%0d replays=%0d",
                 fetch_count_q, dbg_retired, vec_request_count_q,
                 vec_replay_count_q);
        $finish;
    end

endmodule
