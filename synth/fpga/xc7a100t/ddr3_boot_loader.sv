// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Compact block-ROM to native-MIG boot image copier.

`timescale 1ns/1ps

module openrv64_fpga_boot_rom #(
    parameter INIT_FILE = "",
    parameter MEMORY_PRIMITIVE = "block",
    parameter integer WORDS = 1,
    parameter integer ADDR_WIDTH = (WORDS <= 1) ? 1 : $clog2(WORDS)
) (
    input  logic                  clk_i,
    input  logic                  enable_i,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    output logic [255:0]          data_o
);

`ifdef OPENRV64_XILINX_XPM
    // XPM derives an internal unused-port address width with $clog2(depth).
    // A one-word ROM therefore produces an illegal zero width in Vivado
    // 2026.1. Pad only the physical ROM; the loader's logical word count is
    // unchanged.
    localparam integer XPM_WORDS = (WORDS < 2) ? 2 : WORDS;
    wire unused_sbit_error;
    wire unused_dbit_error;

    xpm_memory_sprom #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .CASCADE_HEIGHT(0),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE(INIT_FILE),
        .MEMORY_INIT_PARAM(""),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE),
        .MEMORY_SIZE(XPM_WORDS * 256),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_A(256),
        .READ_LATENCY_A(1),
        .READ_RESET_VALUE_A("0"),
        .RST_MODE_A("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_MEM_INIT(1),
        .USE_MEM_INIT_MMI(0),
        .WAKEUP_TIME("disable_sleep")
    ) u_rom (
        .sleep(1'b0),
        .clka(clk_i),
        .rsta(1'b0),
        .ena(enable_i),
        .regcea(1'b1),
        .addra(addr_i),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .douta(data_o),
        .sbiterra(unused_sbit_error),
        .dbiterra(unused_dbit_error)
    );
`else
    (* rom_style = "block" *)
    logic [255:0] memory [0:WORDS-1];

    initial begin
        if (INIT_FILE == "")
            $fatal(1, "FPGA boot ROM image path is empty");
        $readmemh(INIT_FILE, memory);
    end

    always_ff @(posedge clk_i) begin
        if (enable_i)
            data_o <= memory[addr_i];
    end
`endif

endmodule

module openrv64_fpga_ddr3_boot_loader #(
    parameter TRAMPOLINE_INIT_FILE = "",
    parameter FIRMWARE_INIT_FILE   = "",
    parameter FIRMWARE_TAIL_INIT_FILE = "",
    parameter PAYLOAD_INIT_FILE    = "",
    parameter FDT_INIT_FILE        = "",
    parameter integer TRAMPOLINE_WORDS = 1,
    parameter integer FIRMWARE_WORDS   = 1,
    parameter integer PAYLOAD_WORDS    = 1,
    parameter integer FDT_WORDS        = 1,
    parameter integer FIRMWARE_SPLIT_WORD = 8192,
    parameter integer TIMEOUT_CYCLES   = 100_000_000
) (
    input  logic         clk_i,
    input  logic         reset_i,
    input  logic         calib_complete_i,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    input  logic         app_rdy_i,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic         app_wdf_rdy_i,

    output logic         done_o,
    output logic         failed_o
);

    localparam logic [2:0] STATE_WAIT  = 3'd0;
    localparam logic [2:0] STATE_FETCH = 3'd1;
    localparam logic [2:0] STATE_WRITE = 3'd2;
    localparam logic [2:0] STATE_DONE  = 3'd3;
    localparam logic [2:0] STATE_FAIL  = 3'd4;

    localparam integer MAX_FRAGMENT_WORDS =
        (TRAMPOLINE_WORDS > FIRMWARE_WORDS) ?
            ((TRAMPOLINE_WORDS > PAYLOAD_WORDS) ?
                ((TRAMPOLINE_WORDS > FDT_WORDS) ?
                    TRAMPOLINE_WORDS : FDT_WORDS) :
                ((PAYLOAD_WORDS > FDT_WORDS) ?
                    PAYLOAD_WORDS : FDT_WORDS)) :
            ((FIRMWARE_WORDS > PAYLOAD_WORDS) ?
                ((FIRMWARE_WORDS > FDT_WORDS) ?
                    FIRMWARE_WORDS : FDT_WORDS) :
                ((PAYLOAD_WORDS > FDT_WORDS) ?
                    PAYLOAD_WORDS : FDT_WORDS));
    localparam integer WORD_INDEX_WIDTH =
        (MAX_FRAGMENT_WORDS <= 1) ? 1 : $clog2(MAX_FRAGMENT_WORDS);
    localparam integer TRAMPOLINE_ADDR_WIDTH =
        (TRAMPOLINE_WORDS <= 1) ? 1 : $clog2(TRAMPOLINE_WORDS);
    localparam integer PAYLOAD_ADDR_WIDTH =
        (PAYLOAD_WORDS <= 1) ? 1 : $clog2(PAYLOAD_WORDS);
    localparam integer FDT_ADDR_WIDTH =
        (FDT_WORDS <= 1) ? 1 : $clog2(FDT_WORDS);
    localparam integer FIRMWARE_HEAD_WORDS =
        (FIRMWARE_WORDS > FIRMWARE_SPLIT_WORD) ?
            FIRMWARE_SPLIT_WORD : FIRMWARE_WORDS;
    localparam integer FIRMWARE_TAIL_WORDS =
        (FIRMWARE_WORDS > FIRMWARE_SPLIT_WORD) ?
            (FIRMWARE_WORDS - FIRMWARE_SPLIT_WORD) : 1;
    localparam integer FIRMWARE_HEAD_ADDR_WIDTH =
        (FIRMWARE_HEAD_WORDS <= 1) ? 1 : $clog2(FIRMWARE_HEAD_WORDS);
    localparam integer FIRMWARE_TAIL_ADDR_WIDTH =
        (FIRMWARE_TAIL_WORDS <= 1) ? 1 : $clog2(FIRMWARE_TAIL_WORDS);
    localparam integer TIMEOUT_WIDTH =
        (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam logic [TIMEOUT_WIDTH-1:0] TIMEOUT_LIMIT =
        TIMEOUT_WIDTH'(TIMEOUT_CYCLES - 1);

    // Native MIG addresses count 32-bit words. Each 256-bit UI word advances
    // the address by eight.
    localparam logic [27:0] TRAMPOLINE_BASE = 28'h000_0000;
    localparam logic [27:0] FIRMWARE_BASE   = 28'h004_0000;
    localparam logic [27:0] PAYLOAD_BASE    = 28'h008_0000;
    localparam logic [27:0] FDT_BASE        = 28'h3fc_0000;

    logic [2:0] state_q;
    logic [1:0] fragment_q;
    logic [WORD_INDEX_WIDTH-1:0] word_index_q;
    logic [255:0] trampoline_data;
    logic [255:0] firmware_head_data;
    logic [255:0] firmware_tail_data;
    logic firmware_tail_select_q;
    logic [255:0] payload_data;
    logic [255:0] fdt_data;
    logic [255:0] word_data;
    logic command_sent_q;
    logic data_sent_q;
    logic [TIMEOUT_WIDTH-1:0] timeout_q;

    function automatic integer fragment_words(input logic [1:0] fragment);
        case (fragment)
            2'd0: fragment_words = TRAMPOLINE_WORDS;
            2'd1: fragment_words = FIRMWARE_WORDS;
            2'd2: fragment_words = PAYLOAD_WORDS;
            default: fragment_words = FDT_WORDS;
        endcase
    endfunction

    function automatic logic [WORD_INDEX_WIDTH-1:0] fragment_last_index(
        input logic [1:0] fragment
    );
        fragment_last_index =
            WORD_INDEX_WIDTH'(fragment_words(fragment) - 1);
    endfunction

    function automatic logic [27:0] fragment_base(
        input logic [1:0] fragment
    );
        case (fragment)
            2'd0: fragment_base = TRAMPOLINE_BASE;
            2'd1: fragment_base = FIRMWARE_BASE;
            2'd2: fragment_base = PAYLOAD_BASE;
            default: fragment_base = FDT_BASE;
        endcase
    endfunction

    initial begin
        if (TRAMPOLINE_WORDS <= 0 || FIRMWARE_WORDS <= 0 ||
            PAYLOAD_WORDS <= 0 || FDT_WORDS <= 0)
            $fatal(1, "DDR3 boot-loader fragment sizes must be positive");
        if (FIRMWARE_SPLIT_WORD <= 0)
            $fatal(1, "DDR3 boot-loader firmware split must be positive");
        if (TRAMPOLINE_INIT_FILE == "" || FIRMWARE_INIT_FILE == "" ||
            PAYLOAD_INIT_FILE == "" || FDT_INIT_FILE == "")
            $fatal(1, "DDR3 boot-loader image path is empty");
        if (FIRMWARE_WORDS > FIRMWARE_SPLIT_WORD &&
            FIRMWARE_TAIL_INIT_FILE == "")
            $fatal(1, "DDR3 boot-loader firmware tail image path is empty");
    end

    openrv64_fpga_boot_rom #(
        .INIT_FILE(TRAMPOLINE_INIT_FILE),
        .MEMORY_PRIMITIVE("distributed"),
        .WORDS(TRAMPOLINE_WORDS),
        .ADDR_WIDTH(TRAMPOLINE_ADDR_WIDTH)
    ) u_trampoline_rom (
        .clk_i(clk_i),
        .enable_i(state_q == STATE_FETCH && fragment_q == 2'd0),
        .addr_i(word_index_q[TRAMPOLINE_ADDR_WIDTH-1:0]),
        .data_o(trampoline_data)
    );

    wire firmware_fetch = state_q == STATE_FETCH && fragment_q == 2'd1;
    wire firmware_tail_fetch = firmware_fetch &&
        (FIRMWARE_WORDS > FIRMWARE_SPLIT_WORD) &&
        (word_index_q >= WORD_INDEX_WIDTH'(FIRMWARE_SPLIT_WORD));
    wire [WORD_INDEX_WIDTH-1:0] firmware_tail_offset =
        word_index_q - WORD_INDEX_WIDTH'(FIRMWARE_SPLIT_WORD);

    openrv64_fpga_boot_rom #(
        .INIT_FILE(FIRMWARE_INIT_FILE),
        .MEMORY_PRIMITIVE("block"),
        .WORDS(FIRMWARE_HEAD_WORDS),
        .ADDR_WIDTH(FIRMWARE_HEAD_ADDR_WIDTH)
    ) u_firmware_head_rom (
        .clk_i(clk_i),
        .enable_i(firmware_fetch && !firmware_tail_fetch),
        .addr_i(word_index_q[FIRMWARE_HEAD_ADDR_WIDTH-1:0]),
        .data_o(firmware_head_data)
    );

    generate
        if (FIRMWARE_WORDS > FIRMWARE_SPLIT_WORD) begin : g_firmware_tail
            openrv64_fpga_boot_rom #(
                .INIT_FILE(FIRMWARE_TAIL_INIT_FILE),
                .MEMORY_PRIMITIVE("block"),
                .WORDS(FIRMWARE_TAIL_WORDS),
                .ADDR_WIDTH(FIRMWARE_TAIL_ADDR_WIDTH)
            ) u_rom (
                .clk_i(clk_i),
                .enable_i(firmware_tail_fetch),
                .addr_i(firmware_tail_offset[
                    FIRMWARE_TAIL_ADDR_WIDTH-1:0]),
                .data_o(firmware_tail_data)
            );
        end else begin : g_no_firmware_tail
            assign firmware_tail_data = '0;
        end
    endgenerate

    openrv64_fpga_boot_rom #(
        .INIT_FILE(PAYLOAD_INIT_FILE),
        .MEMORY_PRIMITIVE("distributed"),
        .WORDS(PAYLOAD_WORDS),
        .ADDR_WIDTH(PAYLOAD_ADDR_WIDTH)
    ) u_payload_rom (
        .clk_i(clk_i),
        .enable_i(state_q == STATE_FETCH && fragment_q == 2'd2),
        .addr_i(word_index_q[PAYLOAD_ADDR_WIDTH-1:0]),
        .data_o(payload_data)
    );

    openrv64_fpga_boot_rom #(
        .INIT_FILE(FDT_INIT_FILE),
        .MEMORY_PRIMITIVE("distributed"),
        .WORDS(FDT_WORDS),
        .ADDR_WIDTH(FDT_ADDR_WIDTH)
    ) u_fdt_rom (
        .clk_i(clk_i),
        .enable_i(state_q == STATE_FETCH && fragment_q == 2'd3),
        .addr_i(word_index_q[FDT_ADDR_WIDTH-1:0]),
        .data_o(fdt_data)
    );

    wire command_fire = app_en_o && app_rdy_i;
    wire data_fire = app_wdf_wren_o && app_wdf_rdy_i;
    wire write_complete = (command_sent_q || command_fire) &&
                          (data_sent_q || data_fire);
    wire last_word =
        (word_index_q == fragment_last_index(fragment_q));

    always_comb begin
        case (fragment_q)
            2'd0: word_data = trampoline_data;
            2'd1: word_data = firmware_tail_select_q ?
                              firmware_tail_data : firmware_head_data;
            2'd2: word_data = payload_data;
            default: word_data = fdt_data;
        endcase
        app_addr_o = fragment_base(fragment_q) +
                     ({{(28-WORD_INDEX_WIDTH){1'b0}}, word_index_q} << 3);
        app_cmd_o = 3'b000;
        app_en_o = (state_q == STATE_WRITE) && !command_sent_q;
        app_wdf_data_o = word_data;
        app_wdf_mask_o = 32'h0000_0000;
        app_wdf_wren_o = (state_q == STATE_WRITE) && !data_sent_q;
        app_wdf_end_o = app_wdf_wren_o;
        done_o = (state_q == STATE_DONE);
        failed_o = (state_q == STATE_FAIL);
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= STATE_WAIT;
            fragment_q <= 2'd0;
            word_index_q <= '0;
            command_sent_q <= 1'b0;
            data_sent_q <= 1'b0;
            firmware_tail_select_q <= 1'b0;
            timeout_q <= '0;
        end else begin
            case (state_q)
                STATE_WAIT: begin
                    if (calib_complete_i) begin
                        fragment_q <= 2'd0;
                        word_index_q <= '0;
                        timeout_q <= '0;
                        state_q <= STATE_FETCH;
                    end
                end

                STATE_FETCH: begin
                    command_sent_q <= 1'b0;
                    data_sent_q <= 1'b0;
                    firmware_tail_select_q <= firmware_tail_fetch;
                    timeout_q <= '0;
                    if (!calib_complete_i)
                        state_q <= STATE_FAIL;
                    else
                        state_q <= STATE_WRITE;
                end

                STATE_WRITE: begin
                    if (!calib_complete_i) begin
                        state_q <= STATE_FAIL;
                    end else if (TIMEOUT_CYCLES > 0 &&
                                 timeout_q == TIMEOUT_LIMIT) begin
                        state_q <= STATE_FAIL;
                    end else if (write_complete) begin
                        command_sent_q <= 1'b0;
                        data_sent_q <= 1'b0;
                        timeout_q <= '0;
                        if (last_word) begin
                            word_index_q <= '0;
                            if (fragment_q == 2'd3)
                                state_q <= STATE_DONE;
                            else begin
                                fragment_q <= fragment_q + 2'd1;
                                state_q <= STATE_FETCH;
                            end
                        end else begin
                            word_index_q <= word_index_q + 1'b1;
                            state_q <= STATE_FETCH;
                        end
                    end else begin
                        if (command_fire)
                            command_sent_q <= 1'b1;
                        if (data_fire)
                            data_sent_q <= 1'b1;
                        timeout_q <= timeout_q + 1'b1;
                    end
                end

                STATE_DONE: begin
                    if (!calib_complete_i)
                        state_q <= STATE_FAIL;
                end

                default: state_q <= STATE_FAIL;
            endcase
        end
    end

endmodule
