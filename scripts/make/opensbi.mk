# OpenSBI and Linux build and simulation workflows.

FPGA_SD_IMAGE ?= \
	build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd.bin
FPGA_SD_MANIFEST ?= $(FPGA_SD_IMAGE).json
FPGA_SD_DTS ?= sw/opensbi.dts
FPGA_SD_OPENSBI ?= build/opensbi-fpga-linux/artifacts/fw_jump.bin
FPGA_SD_LINUX ?= sw/Image.Zicclsm
FPGA_SD_TIMEBASE_FREQUENCY ?= 9216000
FPGA_SD_UART_CLOCK_FREQUENCY ?= 9216000
FPGA_SD_ETHERNET ?= 0
FPGA_SD_DEBUG ?= 0
FPGA_OPENSBI_BUILD_DIR ?= build/opensbi-fpga-linux
FPGA_OPENSBI_SOURCE_DIR ?= build/opensbi/src
FPGA_OPENSBI_FW_JUMP_BIN := \
	$(FPGA_OPENSBI_BUILD_DIR)/artifacts/fw_jump.bin
FPGA_OPENSBI_FW_JUMP_ELF := \
	$(FPGA_OPENSBI_BUILD_DIR)/artifacts/fw_jump.elf
FPGA_OPENSBI_DTS := $(FPGA_OPENSBI_BUILD_DIR)/artifacts/openrv64.dts
FPGA_OPENSBI_NM ?= riscv64-linux-gnu-nm
FPGA_DEBUG_SNAPSHOT_SYNTH_DIR ?= \
	build/fpga/xc7a100t/debug-snapshot-synth
FPGA_DEBUG_SNAPSHOT_SYNTH_JSON := \
	$(FPGA_DEBUG_SNAPSHOT_SYNTH_DIR)/snapshot.json
FPGA_DEBUG_SNAPSHOT_SYNTH_LOG := \
	$(FPGA_DEBUG_SNAPSHOT_SYNTH_DIR)/yosys.log
FPGA_DEBUG_STUB_SYNTH_DIR ?= \
	build/fpga/xc7a100t/debug-stub-synth
FPGA_DEBUG_STUB_SYNTH_JSON := \
	$(FPGA_DEBUG_STUB_SYNTH_DIR)/stub.json
FPGA_DEBUG_STUB_SYNTH_LOG := \
	$(FPGA_DEBUG_STUB_SYNTH_DIR)/yosys.log
FPGA_DEBUG_UART_TRACE_SYNTH_DIR ?= \
	build/fpga/xc7a100t/debug-uart-trace-synth
FPGA_DEBUG_UART_TRACE_SYNTH_JSON := \
	$(FPGA_DEBUG_UART_TRACE_SYNTH_DIR)/uart-trace.json
FPGA_DEBUG_UART_TRACE_SYNTH_LOG := \
	$(FPGA_DEBUG_UART_TRACE_SYNTH_DIR)/yosys.log
FPGA_SD_BOOT_DIR ?= build/fpga/xc7a100t/sd-boot
FPGA_SD_BOOT_OUTPUT_DIR ?= \
	$(if $(OUT_DIR),$(OUT_DIR),build/fpga/xc7a100t/sd-boot)
FPGA_SD_BOOT_BITSTREAM := \
	$(FPGA_SD_BOOT_OUTPUT_DIR)/openrv64_myd_j7a100t_sd_boot.bit
FPGA_SD_BOOT_TIMING_REPORT := \
	$(FPGA_SD_BOOT_OUTPUT_DIR)/reports/timing_summary.rpt
FPGA_SD_BOOT_POST_ROUTE_DCP := \
	$(FPGA_SD_BOOT_OUTPUT_DIR)/reports/post_route.dcp
FPGA_SD_BOOT_CORE_TIMING_MAX_PATHS ?= 10
FPGA_SD_BOOT_CORE_TIMING_REPORT_NAME ?= timing_strict_core.rpt
FPGA_SD_BOOT_CORE_TIMING_REPORT := \
	$(FPGA_SD_BOOT_OUTPUT_DIR)/reports/$(FPGA_SD_BOOT_CORE_TIMING_REPORT_NAME)
FPGA_SD_BOOT_UART_DIVISOR ?= 5
FPGA_SD_BOOT_CPPFLAGS ?=
FPGA_SD_BOOT_ELF := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.elf
FPGA_SD_BOOT_BIN := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.bin
FPGA_SD_BOOT_MEM := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.mem
FPGA_VIVADO ?= /home/bill/bin/vivado
FPGA_HW_SERVER_URL ?= TCP:10.1.6.21:3121
FPGA_JTAG_SNOOP ?= tools/fpga-jtag-snoop
FPGA_JTAG_SNOOP_ARGS ?= status
FPGA_DEBUG_DTB_PROBE_DIR ?= build/fpga/xc7a100t/debug-dtb-probe
FPGA_DEBUG_DTB_PROBE_ELF := $(FPGA_DEBUG_DTB_PROBE_DIR)/dtb-probe.elf
FPGA_DEBUG_DTB_PROBE_BIN := $(FPGA_DEBUG_DTB_PROBE_DIR)/dtb-probe.bin
FPGA_DEBUG_DTB_PROBE_DIS := $(FPGA_DEBUG_DTB_PROBE_DIR)/dtb-probe.dis
FPGA_DEBUG_STRCMP_PROBE_DIR ?= build/fpga/xc7a100t/debug-strcmp-probe
FPGA_DEBUG_STRCMP_PROBE_ELF := $(FPGA_DEBUG_STRCMP_PROBE_DIR)/strcmp-probe.elf
FPGA_DEBUG_STRCMP_PROBE_BIN := $(FPGA_DEBUG_STRCMP_PROBE_DIR)/strcmp-probe.bin
FPGA_DEBUG_STRCMP_PROBE_DIS := $(FPGA_DEBUG_STRCMP_PROBE_DIR)/strcmp-probe.dis
FPGA_DEBUG_MEMBLOCK_PROBE_DIR ?= build/fpga/xc7a100t/debug-memblock-probe
FPGA_DEBUG_MEMBLOCK_PROBE_ELF := $(FPGA_DEBUG_MEMBLOCK_PROBE_DIR)/memblock-probe.elf
FPGA_DEBUG_MEMBLOCK_PROBE_BIN := $(FPGA_DEBUG_MEMBLOCK_PROBE_DIR)/memblock-probe.bin
FPGA_DEBUG_MEMBLOCK_PROBE_DIS := $(FPGA_DEBUG_MEMBLOCK_PROBE_DIR)/memblock-probe.dis
FPGA_DEBUG_PING_DIR ?= build/fpga/xc7a100t/debug-ping
FPGA_DEBUG_PING_ELF := $(FPGA_DEBUG_PING_DIR)/ping.elf
FPGA_DEBUG_PING_BIN := $(FPGA_DEBUG_PING_DIR)/ping.bin
FPGA_DEBUG_PING_DIS := $(FPGA_DEBUG_PING_DIR)/ping.dis
FPGA_OPENSBI_CORE_OUTPUT_DIR ?= \
	build/fpga/xc7a100t/opensbi-core
FPGA_OPENSBI_CORE_EDIF := \
	$(FPGA_OPENSBI_CORE_OUTPUT_DIR)/openrv64_fpga_core.edif
FPGA_OPENSBI_CORE_JSON := \
	$(FPGA_OPENSBI_CORE_OUTPUT_DIR)/openrv64_fpga_core.json
FPGA_OPENSBI_CORE_STUB := \
	$(FPGA_OPENSBI_CORE_OUTPUT_DIR)/openrv64_fpga_core_stub.v
FPGA_OPENSBI_CORE_DCP := \
	$(FPGA_OPENSBI_CORE_OUTPUT_DIR)/openrv64_fpga_core.dcp
FPGA_OPENSBI_BP_TYPE ?= 5
FPGA_OPENSBI_ENABLE_TRACE ?= 0
FPGA_OPENSBI_DEBUG_SERIALIZE_ALL_1P ?= 0

fpga-opensbi-core-dcp:
	OUT_DIR='$(FPGA_OPENSBI_CORE_OUTPUT_DIR)' \
		OUTPUT_EDIF='$(FPGA_OPENSBI_CORE_EDIF)' \
		OUTPUT_JSON='$(FPGA_OPENSBI_CORE_JSON)' \
		OUTPUT_STUB='$(FPGA_OPENSBI_CORE_STUB)' \
		BP_TYPE='$(FPGA_OPENSBI_BP_TYPE)' \
		ENABLE_TRACE='$(FPGA_OPENSBI_ENABLE_TRACE)' \
		DEBUG_SERIALIZE_ALL_1P='$(FPGA_OPENSBI_DEBUG_SERIALIZE_ALL_1P)' \
		synth/fpga/xc7a100t/build_yosys_opensbi_core.sh
	$(FPGA_VIVADO) -mode batch -nojournal -nolog \
		-source synth/fpga/xc7a100t/build_vivado_opensbi_core_dcp.tcl \
		-tclargs '$(FPGA_OPENSBI_CORE_EDIF)' \
		'$(FPGA_OPENSBI_CORE_DCP)'
	@test -s '$(FPGA_OPENSBI_CORE_STUB)'
	@test -s '$(FPGA_OPENSBI_CORE_DCP)'
	@printf 'OPENRV64 FPGA CORE DCP PASS path=%s\n' \
		'$(FPGA_OPENSBI_CORE_DCP)'

$(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON): rtl/soc/debug/snapshot_mem.sv
	@mkdir -p '$(FPGA_DEBUG_SNAPSHOT_SYNTH_DIR)'
	yosys -q -l '$(FPGA_DEBUG_SNAPSHOT_SYNTH_LOG)' -p \
		'read_verilog -sv $<; hierarchy -check -top openrv64_soc_debug_snapshot_mem; synth_xilinx -family xc7 -top openrv64_soc_debug_snapshot_mem; stat; write_json $@'

fpga-debug-snapshot-synth: $(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON)

verify-fpga-debug-snapshot-synth:
	@test -s '$(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON)'
	@rg -q '"type": "RAMB(18|36)E1"' \
		'$(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON)'
	@printf 'OPENRV64 FPGA DEBUG SNAPSHOT BRAM PASS path=%s sha256=%s\n' \
		'$(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON)' \
		"$$(sha256sum '$(FPGA_DEBUG_SNAPSHOT_SYNTH_JSON)' | cut -d ' ' -f 1)"

$(FPGA_DEBUG_STUB_SYNTH_JSON): rtl/soc/debug/stub_mem.sv
	@mkdir -p '$(FPGA_DEBUG_STUB_SYNTH_DIR)'
	yosys -q -l '$(FPGA_DEBUG_STUB_SYNTH_LOG)' -p \
		'read_verilog -sv $<; hierarchy -check -top openrv64_soc_debug_stub_mem; synth_xilinx -family xc7 -top openrv64_soc_debug_stub_mem; stat; write_json $@'

fpga-debug-stub-synth: $(FPGA_DEBUG_STUB_SYNTH_JSON)

verify-fpga-debug-stub-synth:
	@test -s '$(FPGA_DEBUG_STUB_SYNTH_JSON)'
	@test "$$(rg -c '"type": "RAMB36E1"' \
		'$(FPGA_DEBUG_STUB_SYNTH_JSON)')" -eq 5
	@printf 'OPENRV64 FPGA DEBUG STUB BRAM PASS path=%s sha256=%s\n' \
		'$(FPGA_DEBUG_STUB_SYNTH_JSON)' \
		"$$(sha256sum '$(FPGA_DEBUG_STUB_SYNTH_JSON)' | cut -d ' ' -f 1)"

$(FPGA_DEBUG_UART_TRACE_SYNTH_JSON): rtl/soc/debug/uart_trace_mem.sv
	@mkdir -p '$(FPGA_DEBUG_UART_TRACE_SYNTH_DIR)'
	yosys -q -l '$(FPGA_DEBUG_UART_TRACE_SYNTH_LOG)' -p \
		'read_verilog -sv $<; hierarchy -check -top openrv64_soc_debug_uart_trace_mem; synth_xilinx -family xc7 -top openrv64_soc_debug_uart_trace_mem; stat; write_json $@'

fpga-debug-uart-trace-synth: $(FPGA_DEBUG_UART_TRACE_SYNTH_JSON)

verify-fpga-debug-uart-trace-synth:
	@test -s '$(FPGA_DEBUG_UART_TRACE_SYNTH_JSON)'
	@test "$$(rg -c '"type": "RAMB36E1"' \
		'$(FPGA_DEBUG_UART_TRACE_SYNTH_JSON)')" -eq 4
	@printf 'OPENRV64 FPGA DEBUG UART TRACE BRAM PASS path=%s sha256=%s\n' \
		'$(FPGA_DEBUG_UART_TRACE_SYNTH_JSON)' \
		"$$(sha256sum '$(FPGA_DEBUG_UART_TRACE_SYNTH_JSON)' | cut -d ' ' -f 1)"

$(FPGA_SD_BOOT_ELF): sw/fpga_sd_boot.S sw/fpga_sd_boot.ld
	@mkdir -p $(dir $@)
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles -static \
		-DFPGA_SD_BOOT_UART_DIVISOR=$(FPGA_SD_BOOT_UART_DIVISOR) \
		$(FPGA_SD_BOOT_CPPFLAGS) \
		-Wl,--build-id=none -Wl,-T,sw/fpga_sd_boot.ld -o $@ $<

$(FPGA_SD_BOOT_BIN): $(FPGA_SD_BOOT_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FPGA_SD_BOOT_MEM): $(FPGA_SD_BOOT_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 4096 --word-bytes 8

fpga-sd-boot-rom: $(FPGA_SD_BOOT_MEM)
	@printf 'OPENRV64 FPGA SD BOOT ROM PASS path=%s bytes=%s\n' \
		'$(FPGA_SD_BOOT_MEM)' "$$(stat -c %s '$(FPGA_SD_BOOT_BIN)')"

fpga-sd-boot-bitstream: $(FPGA_SD_BOOT_MEM)
	synth/fpga/xc7a100t/build_sd_boot_bitstream.sh

fpga-sd-boot-bitstream-check:
	@test -s '$(FPGA_SD_BOOT_BITSTREAM)'
	@test -s '$(FPGA_SD_BOOT_TIMING_REPORT)'
	@rg -q '^All user specified timing constraints are met\.$$' \
		'$(FPGA_SD_BOOT_TIMING_REPORT)'
	@printf 'OPENRV64 FPGA SD BOOT BITSTREAM CHECK PASS path=%s sha256=%s\n' \
		'$(FPGA_SD_BOOT_BITSTREAM)' \
		"$$(sha256sum '$(FPGA_SD_BOOT_BITSTREAM)' | cut -d ' ' -f 1)"

fpga-program-bitstream: fpga-sd-boot-bitstream-check
	$(FPGA_VIVADO) -mode batch -nojournal -nolog \
		-source synth/fpga/xc7a100t/program_bitstream.tcl \
		-tclargs '$(FPGA_HW_SERVER_URL)' '$(FPGA_SD_BOOT_BITSTREAM)'

fpga-jtag-live-tools-check:
	@test -x '$(FPGA_JTAG_SNOOP)'
	@test -r tools/fpga-jtag-snoop.tcl
	@printf 'OPENRV64 FPGA JTAG LIVE TOOLS CHECK PASS wrapper=%s\n' \
		'$(FPGA_JTAG_SNOOP)'

fpga-jtag-snoop:
	FPGA_HW_SERVER_URL='$(FPGA_HW_SERVER_URL)' \
		$(FPGA_JTAG_SNOOP) $(FPGA_JTAG_SNOOP_ARGS)

$(FPGA_DEBUG_DTB_PROBE_BIN): tools/fpga-debug-dtb-probe.S
	@mkdir -p '$(FPGA_DEBUG_DTB_PROBE_DIR)'
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles \
		-Wl,--build-id=none -Wl,-Ttext=0x0c304000 \
		-o '$(FPGA_DEBUG_DTB_PROBE_ELF)' $<
	$(RISCV_OBJCOPY) -O binary '$(FPGA_DEBUG_DTB_PROBE_ELF)' $@
	$(RISCV_OBJDUMP) -d '$(FPGA_DEBUG_DTB_PROBE_ELF)' > \
		'$(FPGA_DEBUG_DTB_PROBE_DIS)'
	@test "$$(stat -c %s '$@')" -le 16368

fpga-debug-dtb-probe: $(FPGA_DEBUG_DTB_PROBE_BIN)
	@printf 'OPENRV64 FPGA DEBUG DTB PROBE PASS path=%s bytes=%s sha256=%s\n' \
		'$(FPGA_DEBUG_DTB_PROBE_BIN)' \
		"$$(stat -c %s '$(FPGA_DEBUG_DTB_PROBE_BIN)')" \
		"$$(sha256sum '$(FPGA_DEBUG_DTB_PROBE_BIN)' | cut -d ' ' -f 1)"

fpga-debug-dtb-probe-read:
	FPGA_HW_SERVER_URL='$(FPGA_HW_SERVER_URL)' \
		tools/fpga-debug-dtb-probe.py

$(FPGA_DEBUG_STRCMP_PROBE_BIN): tools/fpga-debug-strcmp-probe.S
	@mkdir -p '$(FPGA_DEBUG_STRCMP_PROBE_DIR)'
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles \
		-Wl,--build-id=none -Wl,-Ttext=0x0c304000 \
		-o '$(FPGA_DEBUG_STRCMP_PROBE_ELF)' $<
	$(RISCV_OBJCOPY) -O binary '$(FPGA_DEBUG_STRCMP_PROBE_ELF)' $@
	$(RISCV_OBJDUMP) -d '$(FPGA_DEBUG_STRCMP_PROBE_ELF)' > \
		'$(FPGA_DEBUG_STRCMP_PROBE_DIS)'
	@test "$$(stat -c %s '$@')" -le 16368

.PHONY: fpga-debug-strcmp-probe
fpga-debug-strcmp-probe: $(FPGA_DEBUG_STRCMP_PROBE_BIN)
	@printf 'OPENRV64 FPGA DEBUG STRCMP PROBE PASS path=%s bytes=%s sha256=%s\n' \
		'$(FPGA_DEBUG_STRCMP_PROBE_BIN)' \
		"$$(stat -c %s '$(FPGA_DEBUG_STRCMP_PROBE_BIN)')" \
		"$$(sha256sum '$(FPGA_DEBUG_STRCMP_PROBE_BIN)' | cut -d ' ' -f 1)"

.PHONY: fpga-debug-strcmp-probe-read
fpga-debug-strcmp-probe-read:
	FPGA_HW_SERVER_URL='$(FPGA_HW_SERVER_URL)' \
		tools/fpga-debug-strcmp-probe.py

$(FPGA_DEBUG_MEMBLOCK_PROBE_BIN): tools/fpga-debug-memblock-probe.S
	@mkdir -p '$(FPGA_DEBUG_MEMBLOCK_PROBE_DIR)'
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles \
		-Wl,--build-id=none -Wl,-Ttext=0x0c304000 \
		-o '$(FPGA_DEBUG_MEMBLOCK_PROBE_ELF)' $<
	$(RISCV_OBJCOPY) -O binary '$(FPGA_DEBUG_MEMBLOCK_PROBE_ELF)' $@
	$(RISCV_OBJDUMP) -d '$(FPGA_DEBUG_MEMBLOCK_PROBE_ELF)' > \
		'$(FPGA_DEBUG_MEMBLOCK_PROBE_DIS)'
	@test "$$(stat -c %s '$@')" -le 16368

.PHONY: fpga-debug-memblock-probe
fpga-debug-memblock-probe: $(FPGA_DEBUG_MEMBLOCK_PROBE_BIN)
	@printf 'OPENRV64 FPGA DEBUG MEMBLOCK PROBE PASS path=%s bytes=%s sha256=%s\n' \
		'$(FPGA_DEBUG_MEMBLOCK_PROBE_BIN)' \
		"$$(stat -c %s '$(FPGA_DEBUG_MEMBLOCK_PROBE_BIN)')" \
		"$$(sha256sum '$(FPGA_DEBUG_MEMBLOCK_PROBE_BIN)' | cut -d ' ' -f 1)"

.PHONY: fpga-debug-memblock-probe-read
fpga-debug-memblock-probe-read:
	FPGA_HW_SERVER_URL='$(FPGA_HW_SERVER_URL)' \
		tools/fpga-debug-memblock-probe.py

$(FPGA_DEBUG_PING_BIN): tools/fpga-debug-ping.S
	@mkdir -p '$(FPGA_DEBUG_PING_DIR)'
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles \
		-Wl,--build-id=none -Wl,-Ttext=0x0c304000 \
		-o '$(FPGA_DEBUG_PING_ELF)' $<
	$(RISCV_OBJCOPY) -O binary '$(FPGA_DEBUG_PING_ELF)' $@
	$(RISCV_OBJDUMP) -d '$(FPGA_DEBUG_PING_ELF)' > \
		'$(FPGA_DEBUG_PING_DIS)'
	@test "$$(stat -c %s '$@')" -le 16368

.PHONY: fpga-debug-ping
fpga-debug-ping: $(FPGA_DEBUG_PING_BIN)
	@printf 'OPENRV64 FPGA DEBUG PING PASS path=%s bytes=%s sha256=%s\n' \
		'$(FPGA_DEBUG_PING_BIN)' \
		"$$(stat -c %s '$(FPGA_DEBUG_PING_BIN)')" \
		"$$(sha256sum '$(FPGA_DEBUG_PING_BIN)' | cut -d ' ' -f 1)"

fpga-sd-boot-core-timing-report:
	@test -s '$(FPGA_SD_BOOT_POST_ROUTE_DCP)'
	$(FPGA_VIVADO) -mode batch -nojournal -nolog \
		-source synth/fpga/xc7a100t/report_vivado_core_timing.tcl \
		-tclargs '$(FPGA_SD_BOOT_POST_ROUTE_DCP)' \
		'$(FPGA_SD_BOOT_OUTPUT_DIR)/reports' \
		'$(FPGA_SD_BOOT_CORE_TIMING_MAX_PATHS)' \
		'$(FPGA_SD_BOOT_CORE_TIMING_REPORT_NAME)'
	@test -s '$(FPGA_SD_BOOT_CORE_TIMING_REPORT)'

fpga-sd-boot-core-timing-report-check:
	@test -s '$(FPGA_SD_BOOT_CORE_TIMING_REPORT)'
	@rg -q '^Slack \((MET|VIOLATED)\)' \
		'$(FPGA_SD_BOOT_CORE_TIMING_REPORT)'
	@printf 'OPENRV64 FPGA CORE TIMING REPORT CHECK PASS path=%s\n' \
		'$(FPGA_SD_BOOT_CORE_TIMING_REPORT)'

$(FPGA_SD_IMAGE): tools/make-fpga-sd-image.py \
		$(FPGA_SD_DTS) $(FPGA_SD_OPENSBI) $(FPGA_SD_LINUX)
	python3 tools/make-fpga-sd-image.py \
		--timebase-frequency $(FPGA_SD_TIMEBASE_FREQUENCY) \
		--uart-clock-frequency $(FPGA_SD_UART_CLOCK_FREQUENCY) \
		$(if $(filter 1,$(FPGA_SD_ETHERNET)),--ethernet) \
		$(if $(filter 1,$(FPGA_SD_DEBUG)),--fpga-debug) \
		$(FPGA_SD_DTS) $(FPGA_SD_OPENSBI) $(FPGA_SD_LINUX) $@ \
		--manifest $(FPGA_SD_MANIFEST)

fpga-sd-image: $(FPGA_SD_IMAGE)

verify-fpga-sd-image: $(FPGA_SD_IMAGE)
	python3 tools/make-fpga-sd-image.py --verify $(FPGA_SD_IMAGE)
	@echo 'OPENRV64 FPGA SD IMAGE PASS'
	@printf 'FPGA_SD_IMAGE_RESULT path=%s bytes=%s sha256=%s\n' \
		'$(FPGA_SD_IMAGE)' \
		"$$(stat -c %s '$(FPGA_SD_IMAGE)')" \
		"$$(sha256sum '$(FPGA_SD_IMAGE)' | cut -d ' ' -f 1)"

opensbi:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_FDT_ADDR) \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-fpga-linux-debug:
	OPENSBI_BUILD_DIR=$(abspath $(FPGA_OPENSBI_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(FPGA_OPENSBI_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=0x10000000 \
		OPENSBI_FDT_ADDR=0x8ff00000 \
		OPENRV64_HART_COUNT=1 \
		OPENRV64_FPGA_DEBUG=1 \
		OPENRV64_ETHERNET=$(FPGA_SD_ETHERNET) \
		OPENRV64_TIMEBASE_FREQUENCY=$(FPGA_SD_TIMEBASE_FREQUENCY) \
		OPENRV64_UART_CLOCK_FREQUENCY=$(FPGA_SD_UART_CLOCK_FREQUENCY) \
		OPENRV64_ZBB=0 OPENRV64_ZICCLSM=1 \
		tools/build-opensbi.sh

verify-opensbi-fpga-linux-debug:
	@test -s '$(FPGA_OPENSBI_FW_JUMP_BIN)'
	@test -s '$(FPGA_OPENSBI_FW_JUMP_ELF)'
	@test -s '$(FPGA_OPENSBI_DTS)'
	@$(FPGA_OPENSBI_NM) -a '$(FPGA_OPENSBI_FW_JUMP_ELF)' | \
		rg -q '[[:space:]]openrv64_debug_irq$$'
	@$(FPGA_OPENSBI_NM) -a '$(FPGA_OPENSBI_FW_JUMP_ELF)' | \
		rg -q '[[:space:]]openrv64_debug_final_exit$$'
	@rg -q 'compatible = "openrv64,fpga-debug", "openrv64,platform";' \
		'$(FPGA_OPENSBI_DTS)'
	@rg -q 'interrupts-extended = <&cpu0_intc 11>, <&cpu0_intc 9>;' \
		'$(FPGA_OPENSBI_DTS)'
	@printf 'OPENRV64 FPGA DEBUG OPENSBI PASS source=32 path=%s sha256=%s\n' \
		'$(FPGA_OPENSBI_FW_JUMP_BIN)' \
		"$$(sha256sum '$(FPGA_OPENSBI_FW_JUMP_BIN)' | cut -d ' ' -f 1)"

opensbi-4h-held:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_4H_HELD_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_4H_HELD_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_4H_HELD_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_4H_HELD_FDT_ADDR) \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-4h-smp:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_4H_SMP_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_4H_SMP_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_4H_SMP_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_4H_SMP_FDT_ADDR) \
		OPENRV64_HART_COUNT=4 \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-1h-linux-coherent:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_1H_LINUX_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_1H_LINUX_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_SMP_LINUX_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_SMP_LINUX_FDT_ADDR) \
		OPENRV64_HART_COUNT=1 \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-2h-linux-smp:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_2H_LINUX_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_2H_LINUX_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_SMP_LINUX_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_SMP_LINUX_FDT_ADDR) \
		OPENRV64_HART_COUNT=2 \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-4h-linux-smp:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_4H_LINUX_SMP_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_4H_LINUX_SMP_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_SMP_LINUX_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_SMP_LINUX_FDT_ADDR) \
		OPENRV64_HART_COUNT=4 \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-2h-hart-start:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_2H_HART_START_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_2H_HART_START_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_4H_SMP_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_4H_SMP_FDT_ADDR) \
		OPENRV64_HART_COUNT=2 \
		OPENRV64_PAYLOAD_SOURCE=$(abspath $(OPENSBI_HART_START_PAYLOAD_SOURCE)) \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

opensbi-4h-hart-start:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_4H_HART_START_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_4H_HART_START_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_4H_SMP_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_4H_SMP_FDT_ADDR) \
		OPENRV64_HART_COUNT=4 \
		OPENRV64_PAYLOAD_SOURCE=$(abspath $(OPENSBI_HART_START_PAYLOAD_SOURCE)) \
		OPENRV64_ZBB=$(OPENSBI_3P_ADVERTISE_ZBB) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ADVERTISE_ZICCLSM) \
		tools/build-opensbi.sh

sim-opensbi-4h-held: $(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		opensbi-4h-held
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_held \
		+trampoline_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_4H_HELD_MAX_CYCLES)

sim-linux-4h-held:
	$(MAKE) --no-print-directory \
		OPENSBI_4H_HELD_MEMORY_BYTES=$(OPENSBI_4H_LINUX_MEMORY_BYTES) \
		OPENSBI_4H_HELD_MEMORY_SIZE=$(OPENSBI_4H_LINUX_MEMORY_SIZE) \
		OPENSBI_4H_HELD_FDT_ADDR=$(OPENSBI_4H_LINUX_FDT_ADDR) \
		OPENSBI_4H_HELD_FDT_BASE=$(OPENSBI_4H_LINUX_FDT_BASE) \
		OPENSBI_4H_HELD_MAX_CYCLES=$(OPENSBI_4H_LINUX_MAX_CYCLES) \
		LINUX_IMAGE=$(OPENSBI_4H_LINUX_IMAGE) \
		sim-linux-4h-held-configured

sim-linux-4h-held-configured: $(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		opensbi-4h-held $(LINUX_IMAGE_MEMH)
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_held +linux_mode \
		+trampoline_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(LINUX_IMAGE_MEMH) \
		+payload_words=$(LINUX_IMAGE_WORDS) \
		+fdt_memh=$(OPENSBI_4H_HELD_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_4H_HELD_MAX_CYCLES)

sim-linux-2h-smp:
	$(MAKE) --no-print-directory \
		OPENSBI_4H_HELD_MEMORY_BYTES=$(OPENSBI_SMP_LINUX_MEMORY_BYTES) \
		OPENSBI_4H_HELD_MEMORY_SIZE=$(OPENSBI_SMP_LINUX_MEMORY_SIZE) \
		OPENSBI_4H_HELD_FDT_ADDR=$(OPENSBI_SMP_LINUX_FDT_ADDR) \
		OPENSBI_4H_HELD_FDT_BASE=$(OPENSBI_SMP_LINUX_FDT_BASE) \
		OPENSBI_4H_HELD_MAX_CYCLES=$(OPENSBI_SMP_LINUX_MAX_CYCLES) \
		OPENSBI_4H_HELD_VERILATOR_THREADS=$(OPENSBI_2H_LINUX_VERILATOR_THREADS) \
		LINUX_IMAGE=$(OPENSBI_SMP_LINUX_IMAGE) \
		LINUX_IMAGE_MEMH=$(OPENSBI_2H_LINUX_IMAGE_MEMH) \
		sim-linux-2h-smp-configured

sim-linux-2h-smp-configured: $(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		opensbi-2h-linux-smp $(LINUX_IMAGE_MEMH)
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_smp +linux_mode \
		+opensbi_active_harts=2 +gate_held_hart_clocks \
		+opensbi_hsm_wfi_pc=$$(sed -n '1p' \
			$(OPENSBI_2H_LINUX_ARTIFACT_DIR)/hsm-wfi-pc.txt) \
		+trampoline_memh=$(OPENSBI_2H_LINUX_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_2H_LINUX_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(LINUX_IMAGE_MEMH) \
		+payload_words=$(LINUX_IMAGE_WORDS) \
		+fdt_memh=$(OPENSBI_2H_LINUX_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_4H_HELD_MAX_CYCLES)

sim-linux-4h-smp:
	$(MAKE) --no-print-directory \
		OPENSBI_4H_HELD_MEMORY_BYTES=$(OPENSBI_SMP_LINUX_MEMORY_BYTES) \
		OPENSBI_4H_HELD_MEMORY_SIZE=$(OPENSBI_SMP_LINUX_MEMORY_SIZE) \
		OPENSBI_4H_HELD_FDT_ADDR=$(OPENSBI_SMP_LINUX_FDT_ADDR) \
		OPENSBI_4H_HELD_FDT_BASE=$(OPENSBI_SMP_LINUX_FDT_BASE) \
		OPENSBI_4H_HELD_MAX_CYCLES=$(OPENSBI_SMP_LINUX_MAX_CYCLES) \
		OPENSBI_4H_HELD_VERILATOR_THREADS=$(OPENSBI_4H_LINUX_VERILATOR_THREADS) \
		LINUX_IMAGE=$(OPENSBI_SMP_LINUX_IMAGE) \
		LINUX_IMAGE_MEMH=$(OPENSBI_4H_LINUX_SMP_IMAGE_MEMH) \
		sim-linux-4h-smp-configured

sim-linux-4h-smp-configured: $(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		opensbi-4h-linux-smp $(LINUX_IMAGE_MEMH)
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_smp +linux_mode +opensbi_active_harts=4 \
		+opensbi_hsm_wfi_pc=$$(sed -n '1p' \
			$(OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)/hsm-wfi-pc.txt) \
		+trampoline_memh=$(OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(LINUX_IMAGE_MEMH) \
		+payload_words=$(LINUX_IMAGE_WORDS) \
		+fdt_memh=$(OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_4H_HELD_MAX_CYCLES)

sim-opensbi-4h-smp: $(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		opensbi-4h-smp
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_smp \
		+opensbi_hsm_wfi_pc=$$(sed -n '1p' \
			$(OPENSBI_4H_SMP_ARTIFACT_DIR)/hsm-wfi-pc.txt) \
		+trampoline_memh=$(OPENSBI_4H_SMP_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_4H_SMP_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_4H_SMP_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_4H_SMP_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_4H_SMP_MAX_CYCLES)

sim-opensbi-2h-hart-start:
	$(MAKE) --no-print-directory \
		OPENSBI_4H_DDR3_ENABLE=$(OPENSBI_HART_START_DDR3_ENABLE) \
		OPENSBI_4H_HELD_VERILATOR_THREADS=$(OPENSBI_2H_HART_START_VERILATOR_THREADS) \
		sim-opensbi-2h-hart-start-configured

sim-opensbi-2h-hart-start-configured: \
		$(OPENSBI_4H_HELD_VERILATOR_BUILD) opensbi-2h-hart-start
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_smp +opensbi_hart_start \
		+opensbi_active_harts=2 +gate_held_hart_clocks \
		+opensbi_hsm_wfi_pc=$$(sed -n '1p' \
			$(OPENSBI_2H_HART_START_ARTIFACT_DIR)/hsm-wfi-pc.txt) \
		+trampoline_memh=$(OPENSBI_2H_HART_START_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_2H_HART_START_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_2H_HART_START_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_2H_HART_START_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_HART_START_MAX_CYCLES)

sim-opensbi-4h-hart-start:
	$(MAKE) --no-print-directory \
		OPENSBI_4H_DDR3_ENABLE=$(OPENSBI_HART_START_DDR3_ENABLE) \
		OPENSBI_4H_HELD_VERILATOR_THREADS=$(OPENSBI_4H_HART_START_VERILATOR_THREADS) \
		sim-opensbi-4h-hart-start-configured

sim-opensbi-4h-hart-start-configured: \
		$(OPENSBI_4H_HELD_VERILATOR_BUILD) opensbi-4h-hart-start
	$(OPENSBI_4H_HELD_VERILATOR_BUILD) \
		+opensbi_smp +opensbi_hart_start \
		+opensbi_active_harts=4 \
		+opensbi_hsm_wfi_pc=$$(sed -n '1p' \
			$(OPENSBI_4H_HART_START_ARTIFACT_DIR)/hsm-wfi-pc.txt) \
		+trampoline_memh=$(OPENSBI_4H_HART_START_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_4H_HART_START_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_4H_HART_START_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_4H_HART_START_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+max_cycles=$(OPENSBI_HART_START_MAX_CYCLES)

sim-opensbi-hart-start: sim-opensbi-2h-hart-start \
	sim-opensbi-4h-hart-start

sim-opensbi: $(OPENSBI_VERILATOR_BUILD) opensbi
	$(OPENSBI_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh

sim-linux: $(OPENSBI_VERILATOR_BUILD) opensbi $(LINUX_IMAGE_MEMH)
	$(OPENSBI_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(LINUX_IMAGE_MEMH) \
		+payload_words=$(LINUX_IMAGE_WORDS) \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh \
		+linux_mode +max_cycles=$(LINUX_MAX_CYCLES)

sim-opensbi-3p: $(OPENSBI_3P_VERILATOR_BUILD) opensbi
	mkdir -p $(dir $(OPENSBI_3P_INSTRUCTION_TRACE))
	$(OPENSBI_3P_VERILATOR_BUILD) \
		+opensbi_trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline-axi.memh \
		+opensbi_firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump-axi.memh \
		+opensbi_payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload-axi.memh \
		+opensbi_fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-3p-dtb-axi.memh \
		+instruction_trace=$(OPENSBI_3P_INSTRUCTION_TRACE) \
		+max_cycles=20000000

sim-opensbi-3p-platform: $(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) opensbi
	$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-3p-dtb.memh

sim-linux-3p-platform-checkpoint: \
		$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) opensbi \
		$(LINUX_IMAGE_MEMH)
	mkdir -p $(dir $(OPENSBI_3P_PLATFORM_CHECKPOINT))
	$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(LINUX_IMAGE_MEMH) \
		+payload_words=$(LINUX_IMAGE_WORDS) \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-3p-dtb.memh \
		+linux_mode +max_cycles=$(LINUX_MAX_CYCLES) \
		+checkpoint=$(OPENSBI_3P_PLATFORM_CHECKPOINT) \
		+checkpoint_cycles=$(OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES) \
		+checkpoint_exit

sim-linux-3p-platform-restore: $(OPENSBI_3P_PLATFORM_VERILATOR_BUILD)
	$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) \
		+restore=$(OPENSBI_3P_PLATFORM_CHECKPOINT)

sim-opensbi-icarus: $(OPENSBI_SIM_BUILD) opensbi
	vvp $(OPENSBI_SIM_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh

$(LINUX_IMAGE_MEMH): $(LINUX_IMAGE) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ --size $(LINUX_IMAGE_SLOT_BYTES)
