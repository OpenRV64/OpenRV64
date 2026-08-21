# OpenSBI and Linux build and simulation workflows.

FPGA_SD_IMAGE ?= \
	build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd.bin
FPGA_SD_MANIFEST ?= $(FPGA_SD_IMAGE).json
FPGA_SD_DTS ?= sw/opensbi.dts
FPGA_SD_OPENSBI ?= build/opensbi-fpga-linux/artifacts/fw_jump.bin
FPGA_SD_LINUX ?= sw/Image.Zicclsm
FPGA_SD_BOOT_DIR ?= build/fpga/xc7a100t/sd-boot
FPGA_SD_BOOT_UART_DIVISOR ?= 5
FPGA_SD_BOOT_ELF := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.elf
FPGA_SD_BOOT_BIN := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.bin
FPGA_SD_BOOT_MEM := $(FPGA_SD_BOOT_DIR)/fpga-sd-boot.mem

$(FPGA_SD_BOOT_ELF): sw/fpga_sd_boot.S sw/fpga_sd_boot.ld
	@mkdir -p $(dir $@)
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles -static \
		-DFPGA_SD_BOOT_UART_DIVISOR=$(FPGA_SD_BOOT_UART_DIVISOR) \
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

$(FPGA_SD_IMAGE): tools/make-fpga-sd-image.py \
		$(FPGA_SD_DTS) $(FPGA_SD_OPENSBI) $(FPGA_SD_LINUX)
	python3 tools/make-fpga-sd-image.py \
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
