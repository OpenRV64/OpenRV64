`timescale 1ns/1ps
`include "core/exec/bp/defs.v"

module tb_fpga_sd_boot #(
    parameter bit PIPE_1P_MEM_4_STAGE = 1'b1,
    parameter bit PIPE_1P_DECODE_QUEUE = 1'b1,
    parameter bit FPGA_GPR_LUTRAM = 1'b1
);
    reg clk;
    reg rst_n;
    wire uart_tx;
    wire spi_clk;
    wire spi_mosi;
    reg spi_miso;
    wire spi_cs_n;
    wire ext_mem_valid;
    reg ext_mem_ready;
    wire ext_mem_write;
    wire [63:0] ext_mem_addr;
    wire [63:0] ext_mem_wdata;
    wire [7:0] ext_mem_wstrb;
    reg [63:0] ext_mem_rdata;
    wire [63:0] dbg_pc;
    wire soc_rst_n;
    wire core_rst_n;

    localparam integer DDR_BYTES = 2 * 1024 * 1024;
    reg [63:0] ddr [0:(DDR_BYTES / 8) - 1];
    localparam integer CARD_BYTES = 17 * 512;
    reg [7:0] card [0:CARD_BYTES-1];
    reg [7:0] command_bytes [0:5];
    reg [7:0] response_bytes [0:519];
    reg [7:0] command_shift;
    integer command_bit_count;
    integer command_byte_count;
    integer response_count;
    integer response_index;
    integer response_bit;
    integer card_ready;
    integer multi_read_active;
    integer multi_read_lba;
    integer cmd17_count;
    integer cmd18_count;
    integer cmd12_count;
    integer overlap_seen;
    integer bank1_ready_seen;
    integer both_banks_ready_seen;

    openrv64_platform #(
        .SOC_RESET_CYCLES(2),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(1),
        .MEMORY_BYTES(DDR_BYTES),
        .ROM_INIT_FILE(
            "build/fpga/xc7a100t/sd-boot/fpga-sd-boot.mem"),
        .SPI_INIT_HALF_PERIOD_CYCLES(1),
        .SPI_FAST_HALF_PERIOD_CYCLES(1),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_1P),
        .PHYS_REG_COUNT(31),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64ZBB(1'b0),
        .PIPE_1P_MEM_4_STAGE(PIPE_1P_MEM_4_STAGE),
        .PIPE_1P_DECODE_QUEUE(PIPE_1P_DECODE_QUEUE),
        .FPGA_GPR_LUTRAM(FPGA_GPR_LUTRAM),
        .UART_INPUT_CLOCK_HZ(30_000_000),
        .UART_REFERENCE_CLOCK_HZ(14_745_600),
        .EXTERNAL_MEMORY_ENABLE(1'b1),
        .PMP_ACTIVE_ENTRIES(8),
        .GENBUS_TLB_ENTRIES(4),
        .PTW_PTE_CACHE_ENTRIES(0),
        .ENABLE_PREDECODE_TARGETS(1'b0),
        .BP_TYPE(`OPENRV64_BP_BIMODAL),
        .BP_RAS_ENABLE(1'b0),
        .BP_BIMODAL_ENTRIES(32)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b0),
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
        .spi_card_present_i(1'b1),
        .spi_clk_o(spi_clk),
        .spi_mosi_o(spi_mosi),
        .spi_miso_i(spi_miso),
        .spi_cs_n_o(spi_cs_n),
        .gpio_in_i(1'b0),
        .gpio_out_o(),
        .external_irq_i(29'd0),
        .ext_mem_valid_o(ext_mem_valid),
        .ext_mem_ready_i(ext_mem_ready),
        .ext_mem_write_o(ext_mem_write),
        .ext_mem_addr_o(ext_mem_addr),
        .ext_mem_wdata_o(ext_mem_wdata),
        .ext_mem_wstrb_o(ext_mem_wstrb),
        .ext_mem_rdata_i(ext_mem_rdata),
        .ext_icx_req_ready_i(1'b0),
        .ext_icx_wdata_ready_i(1'b0),
        .ext_icx_resp_valid_i(1'b0),
        .ext_icx_resp_hart_id_i('0),
        .ext_icx_resp_txn_id_i('0),
        .ext_icx_resp_source_id_i('0),
        .ext_icx_resp_beat_index_i('0),
        .ext_icx_resp_last_i(1'b0),
        .ext_icx_resp_rdata_i('0),
        .ext_icx_resp_error_i(1'b0),
        .ext_icx_resp_sc_success_i(1'b0),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n),
        .dbg_pc(dbg_pc)
    );

    always #5 clk = ~clk;

    reg [1:0] memory_state;
    reg memory_write_q;
    reg [20:0] memory_addr_q;
    reg [63:0] memory_wdata_q;
    reg [7:0] memory_wstrb_q;
    integer write_lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            memory_state <= 0;
            ext_mem_ready <= 0;
            ext_mem_rdata <= 0;
        end else begin
            ext_mem_ready <= 0;
            case (memory_state)
                0: begin
                    if (ext_mem_valid) begin
                        memory_write_q <= ext_mem_write;
                        memory_addr_q <= ext_mem_addr[20:0];
                        memory_wdata_q <= ext_mem_wdata;
                        memory_wstrb_q <= ext_mem_wstrb;
                        memory_state <= 1;
                    end
                end
                1: begin
                    ext_mem_rdata <= ddr[memory_addr_q[20:3]];
                    if (memory_write_q) begin
                        for (write_lane = 0; write_lane < 8;
                             write_lane = write_lane + 1) begin
                            if (memory_wstrb_q[write_lane])
                                ddr[memory_addr_q[20:3]]
                                   [8*write_lane +: 8] <=
                                    memory_wdata_q[8*write_lane +: 8];
                        end
                    end
                    ext_mem_ready <= 1;
                    memory_state <= 2;
                end
                default: memory_state <= 0;
            endcase
        end
    end

    task automatic put_u32;
        input integer offset;
        input [31:0] value;
        begin
            card[offset + 0] = value[7:0];
            card[offset + 1] = value[15:8];
            card[offset + 2] = value[23:16];
            card[offset + 3] = value[31:24];
        end
    endtask

    task automatic put_u64;
        input integer offset;
        input [63:0] value;
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                card[offset + byte_index] = value[8*byte_index +: 8];
        end
    endtask

    function automatic [31:0] card_crc32;
        input integer offset;
        input integer length;
        reg [31:0] crc;
        integer byte_index;
        integer bit_index;
        begin
            crc = 32'hffff_ffff;
            for (byte_index = 0; byte_index < length;
                 byte_index = byte_index + 1) begin
                crc = crc ^ card[offset + byte_index];
                for (bit_index = 0; bit_index < 8;
                     bit_index = bit_index + 1) begin
                    if (crc[0])
                        crc = (crc >> 1) ^ 32'hedb8_8320;
                    else
                        crc = crc >> 1;
                end
            end
            card_crc32 = ~crc;
        end
    endfunction

    task automatic make_entry;
        input integer index;
        input [63:0] tag;
        input [31:0] lba;
        input [31:0] sector_count;
        input [63:0] destination;
        input [31:0] byte_length;
        integer entry_offset;
        begin
            entry_offset = 64 + 32 * index;
            put_u64(entry_offset, tag);
            put_u32(entry_offset + 8, lba);
            put_u32(entry_offset + 12, sector_count);
            put_u64(entry_offset + 16, destination);
            put_u32(entry_offset + 24, byte_length);
            put_u32(entry_offset + 28,
                    card_crc32(lba * 512, byte_length));
        end
    endtask

    task automatic check_payload;
        input integer ddr_offset;
        input integer lba;
        input integer byte_length;
        integer byte_index;
        reg [7:0] actual;
        begin
            for (byte_index = 0; byte_index < byte_length;
                 byte_index = byte_index + 1) begin
                actual = ddr[(ddr_offset + byte_index) >> 3]
                            [8*((ddr_offset + byte_index) & 7) +: 8];
                if (actual !== card[lba * 512 + byte_index])
                    $fatal(1,
                           "DDR payload mismatch ddr=%0x lba=%0d byte=%0d got=%02x expected=%02x",
                           ddr_offset, lba, byte_index, actual,
                           card[lba * 512 + byte_index]);
            end
            actual = ddr[(ddr_offset + byte_length) >> 3]
                        [8*((ddr_offset + byte_length) & 7) +: 8];
            if (actual !== 8'ha5)
                $fatal(1,
                       "payload padding was copied ddr=%0x length=%0d got=%02x",
                       ddr_offset, byte_length, actual);
        end
    endtask

    task automatic queue_data_block;
        input integer lba;
        integer data_index;
        integer lba_offset;
        begin
            lba_offset = lba * 512;
            response_bytes[0] = 8'hff;
            response_bytes[1] = 8'hfe;
            for (data_index = 0; data_index < 512;
                 data_index = data_index + 1)
                response_bytes[2 + data_index] =
                    card[lba_offset + data_index];
            response_bytes[514] = 8'hff;
            response_bytes[515] = 8'hff;
            response_count = 516;
            response_index = 0;
            response_bit = 7;
        end
    endtask

    task automatic queue_command_response;
        reg [5:0] command;
        reg [31:0] argument;
        integer data_index;
        integer lba_offset;
        begin
            command = command_bytes[0][5:0];
            argument = {command_bytes[1], command_bytes[2],
                        command_bytes[3], command_bytes[4]};
            response_count = 0;
            response_index = 0;
            response_bit = 7;
            case (command)
                0: begin
                    response_bytes[0] = 8'h01;
                    response_count = 1;
                end
                8: begin
                    response_bytes[0] = 8'h01;
                    response_bytes[1] = 8'h00;
                    response_bytes[2] = 8'h00;
                    response_bytes[3] = 8'h01;
                    response_bytes[4] = 8'haa;
                    response_count = 5;
                end
                55: begin
                    response_bytes[0] = card_ready ? 8'h00 : 8'h01;
                    response_count = 1;
                end
                41: begin
                    response_bytes[0] = 8'h00;
                    response_count = 1;
                    card_ready = 1;
                end
                58: begin
                    response_bytes[0] = 8'h00;
                    response_bytes[1] = 8'hc0;
                    response_bytes[2] = 8'hff;
                    response_bytes[3] = 8'h80;
                    response_bytes[4] = 8'h00;
                    response_count = 5;
                end
                17: begin
                    cmd17_count = cmd17_count + 1;
                    response_bytes[0] = 8'h00;
                    response_bytes[1] = 8'hff;
                    response_bytes[2] = 8'hfe;
                    lba_offset = argument * 512;
                    for (data_index = 0; data_index < 512;
                         data_index = data_index + 1)
                        response_bytes[3 + data_index] =
                            card[lba_offset + data_index];
                    response_bytes[515] = 8'hff;
                    response_bytes[516] = 8'hff;
                    response_count = 517;
                end
                18: begin
                    cmd18_count = cmd18_count + 1;
                    response_bytes[0] = 8'h00;
                    response_count = 1;
                    multi_read_active = 1;
                    multi_read_lba = argument;
                end
                12: begin
                    cmd12_count = cmd12_count + 1;
                    multi_read_active = 0;
                    /*
                     * CMD12 has one unspecified stuff byte before R1.  Keep
                     * bit 7 clear so generic R1 polling cannot accidentally
                     * accept the stuff byte as the response.
                     */
                    response_bytes[0] = 8'h3f;
                    response_bytes[1] = 8'h00;
                    response_bytes[2] = 8'hff;
                    response_count = 3;
                end
                default: begin
                    response_bytes[0] = 8'h04;
                    response_count = 1;
                end
            endcase
        end
    endtask

    /* Behavioral SDHC SPI slave, sufficient for the ROM's command subset. */
    always @(negedge spi_cs_n) begin
        command_shift = 0;
        command_bit_count = 0;
        command_byte_count = 0;
        response_count = 0;
        response_index = 0;
        response_bit = 7;
        spi_miso = 1'b1;
    end

    always @(posedge spi_cs_n) begin
        multi_read_active = 0;
        spi_miso = 1'b1;
    end

    always @(posedge spi_clk) begin : capture_card_command
        reg [7:0] assembled_byte;
        if (!spi_cs_n) begin
            assembled_byte = {command_shift[6:0], spi_mosi};
            command_shift = assembled_byte;
            command_bit_count = command_bit_count + 1;
            if (command_bit_count == 8) begin
                command_bit_count = 0;
                command_shift = 0;
                if (command_byte_count == 0) begin
                    if (assembled_byte[7:6] == 2'b01) begin
                        command_bytes[0] = assembled_byte;
                        command_byte_count = 1;
                    end
                end else begin
                    command_bytes[command_byte_count] = assembled_byte;
                    command_byte_count = command_byte_count + 1;
                    if (command_byte_count == 6) begin
                        queue_command_response();
                        command_byte_count = 0;
                    end
                end
            end
        end
    end

    always @(negedge spi_clk) begin
        if (!spi_cs_n && response_index >= response_count &&
            multi_read_active && command_byte_count == 0) begin
            queue_data_block(multi_read_lba);
            multi_read_lba = multi_read_lba + 1;
        end
        if (!spi_cs_n && response_index < response_count) begin
            spi_miso = response_bytes[response_index][response_bit];
            if (response_bit == 0) begin
                response_bit = 7;
                response_index = response_index + 1;
            end else begin
                response_bit = response_bit - 1;
            end
        end else begin
            spi_miso = 1'b1;
        end
    end

    integer init_index;
    integer cycle_count;
    integer uart_byte_count;

    function automatic [7:0] expected_uart_byte;
        input integer index;
        begin
            case (index)
                0: expected_uart_byte = "O";
                1: expected_uart_byte = "P";
                2: expected_uart_byte = "E";
                3: expected_uart_byte = "N";
                4: expected_uart_byte = "R";
                5: expected_uart_byte = "V";
                6: expected_uart_byte = "6";
                7: expected_uart_byte = "4";
                8: expected_uart_byte = " ";
                9: expected_uart_byte = "S";
                10: expected_uart_byte = "D";
                11: expected_uart_byte = " ";
                12: expected_uart_byte = "B";
                13: expected_uart_byte = "O";
                14: expected_uart_byte = "O";
                15: expected_uart_byte = "T";
                16: expected_uart_byte = " ";
                17: expected_uart_byte = "S";
                18: expected_uart_byte = "T";
                19: expected_uart_byte = "A";
                20: expected_uart_byte = "R";
                21: expected_uart_byte = "T";
                22: expected_uart_byte = 8'h0d;
                23: expected_uart_byte = 8'h0a;
                default: expected_uart_byte = 8'hxx;
            endcase
        end
    endfunction

    initial begin
        clk = 0;
        rst_n = 0;
        uart_byte_count = 0;
        spi_miso = 1;
        card_ready = 0;
        multi_read_active = 0;
        multi_read_lba = 0;
        cmd17_count = 0;
        cmd18_count = 0;
        cmd12_count = 0;
        overlap_seen = 0;
        bank1_ready_seen = 0;
        both_banks_ready_seen = 0;
        for (init_index = 0; init_index < 2048 / 8;
             init_index = init_index + 1) begin
            ddr[init_index] = 64'ha5a5_a5a5_a5a5_a5a5;
            ddr[(16'h1000 >> 3) + init_index] =
                64'ha5a5_a5a5_a5a5_a5a5;
            ddr[(16'h2000 >> 3) + init_index] =
                64'ha5a5_a5a5_a5a5_a5a5;
            ddr[(16'h3000 >> 3) + init_index] =
                64'ha5a5_a5a5_a5a5_a5a5;
        end
        for (init_index = 0; init_index < CARD_BYTES;
             init_index = init_index + 1)
            card[init_index] = 0;

        /* Four payloads, including exact-length multi-sector entries. */
        for (init_index = 0; init_index < 32; init_index = init_index + 1)
            card[8 * 512 + init_index] = init_index ^ 8'h35;
        put_u32(8 * 512, 32'h0000006f); /* jal zero, 0 */
        for (init_index = 0; init_index < 700; init_index = init_index + 1)
            card[9 * 512 + init_index] = (init_index * 3) ^ 8'h51;
        for (init_index = 0; init_index < 1300; init_index = init_index + 1)
            card[11 * 512 + init_index] = (init_index * 5) ^ 8'ha7;
        for (init_index = 0; init_index < 777; init_index = init_index + 1)
            card[14 * 512 + init_index] = (init_index * 7) ^ 8'hc3;
        /* Nonzero sector padding catches CRC engines that ignore byte_length. */
        for (init_index = 32; init_index < 512; init_index = init_index + 1)
            card[8 * 512 + init_index] = 8'hd1;
        for (init_index = 700; init_index < 2 * 512;
             init_index = init_index + 1)
            card[9 * 512 + init_index] = 8'hd2;
        for (init_index = 1300; init_index < 3 * 512;
             init_index = init_index + 1)
            card[11 * 512 + init_index] = 8'hd3;
        for (init_index = 777; init_index < 2 * 512;
             init_index = init_index + 1)
            card[14 * 512 + init_index] = 8'hd4;

        put_u64(0, 64'h314453343656524f); /* ORV64SD1 */
        put_u32(8, 1);
        put_u32(12, 512);
        put_u32(16, 32);
        put_u32(20, 4);
        put_u64(24, 16 * 512);
        make_entry(0, 64'h000000504d415254, 8, 1,
                   64'h80000000, 32);
        make_entry(1, 64'h000000004942534f, 9, 2,
                   64'h80001000, 700);
        make_entry(2, 64'h00000058554e494c, 11, 3,
                   64'h80002000, 1300);
        make_entry(3, 64'h0000000000544446, 14, 2,
                   64'h80003000, 777);
        put_u32(508, card_crc32(0, 508));

        repeat (8) @(posedge clk);
        rst_n = 1;

        for (cycle_count = 0; cycle_count < 1_000_000;
             cycle_count = cycle_count + 1) begin
            @(posedge clk);
            if (dbg_pc == 64'h80000000) begin
                check_payload(16'h0000, 8, 32);
                check_payload(16'h1000, 9, 700);
                check_payload(16'h2000, 11, 1300);
                check_payload(16'h3000, 14, 777);
`ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
                if (cmd17_count != 9 || cmd18_count != 0 ||
                    cmd12_count != 0)
                    $fatal(1,
                           "bad SD command counts CMD17=%0d CMD18=%0d CMD12=%0d",
                           cmd17_count, cmd18_count, cmd12_count);
                $display("tb_fpga_sd_boot: PASS mode=legacy cycles=%0d sectors=8 CMD17=%0d CMD18=%0d CMD12=%0d",
                         cycle_count, cmd17_count, cmd18_count, cmd12_count);
`else
                if (cmd17_count != 1 || cmd18_count != 4 ||
                    cmd12_count != 4)
                    $fatal(1,
                           "bad SD command counts CMD17=%0d CMD18=%0d CMD12=%0d",
                           cmd17_count, cmd18_count, cmd12_count);
                if (!overlap_seen || !bank1_ready_seen)
                    $fatal(1,
                           "double-buffer coverage missing overlap=%0d bank1=%0d",
                           overlap_seen, bank1_ready_seen);
                if (both_banks_ready_seen)
                    $fatal(1,
                           "hardware-CRC copy path stalled with both banks ready");
                if (dut.u_spi.stream_crc_bytes_remaining_q != 32'd0 ||
                    ~dut.u_spi.stream_crc32_q !==
                    card_crc32(14 * 512, 777))
                    $fatal(1,
                           "hardware CRC mismatch got=%08x remaining=%0d expected=%08x",
                           ~dut.u_spi.stream_crc32_q,
                           dut.u_spi.stream_crc_bytes_remaining_q,
                           card_crc32(14 * 512, 777));
                $display("tb_fpga_sd_boot: PASS mode=double-buffer cycles=%0d sectors=8 CMD17=%0d CMD18=%0d CMD12=%0d overlap=%0d bank1=%0d both_ready=%0d hardware_crc=%08x",
                         cycle_count, cmd17_count, cmd18_count, cmd12_count,
                         overlap_seen, bank1_ready_seen,
                         both_banks_ready_seen, ~dut.u_spi.stream_crc32_q);
`endif
                $finish;
            end
        end
        $fatal(1, "timeout: pc=%016x soc_rst_n=%b core_rst_n=%b",
               dbg_pc, soc_rst_n, core_rst_n);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.u_spi.stream_active_q && ext_mem_valid && ext_mem_write)
                overlap_seen = 1;
            if (dut.u_spi.stream_ready_q[1])
                bank1_ready_seen = 1;
            if (dut.u_spi.stream_ready_q == 2'b11)
                both_banks_ready_seen = 1;
        end
        if (dut.u_uart.write_thr) begin
            if (uart_byte_count < 24 &&
                dut.u_uart.thr_write_data !==
                    expected_uart_byte(uart_byte_count))
                $fatal(1,
                       "UART MMIO byte %0d: got %02x expected %02x pc=%016x",
                       uart_byte_count, dut.u_uart.thr_write_data,
                       expected_uart_byte(uart_byte_count), dbg_pc);
            $write("%c", dut.u_uart.thr_write_data);
            uart_byte_count = uart_byte_count + 1;
        end
    end

endmodule
