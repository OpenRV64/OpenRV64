# OpenSBI and Linux build and simulation workflows.

opensbi:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_BUILD_DIR)) \
		OPENSBI_SOURCE_DIR=$(abspath $(OPENSBI_SOURCE_DIR)) \
		OPENSBI_MEMORY_SIZE=$(OPENSBI_MEMORY_SIZE) \
		OPENSBI_FDT_ADDR=$(OPENSBI_FDT_ADDR) \
		OPENRV64_ZICCLSM=$(OPENSBI_3P_ENABLE_ZICCLSM) \
		tools/build-opensbi.sh

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
