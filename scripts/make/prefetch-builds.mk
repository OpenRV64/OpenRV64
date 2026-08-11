# Prefetch workload and Verilator build recipes.

$(STREAM_ELF): $(OPENRV64_MAKEFILES) sw/stream/stream.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-Wa,--defsym,STREAM_KERNEL=$(STREAM_KERNEL_ID) \
		-Wa,--defsym,STREAM_BYTES=$(STREAM_BYTES) \
		-Wl,--build-id=none,-Map,$(STREAM_MAP) \
		-T sw/openrv64.ld -o $@ sw/stream/stream.S

$(STREAM_BIN): $(STREAM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(STREAM_DISASM): $(STREAM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(STREAM_VM_ELF): $(OPENRV64_MAKEFILES) sw/stream/stream.S \
		sw/stream/stream_vm_boot.S sw/stream/openrv64-stream-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-Wa,--defsym,STREAM_KERNEL=$(STREAM_KERNEL_ID) \
		-Wa,--defsym,STREAM_BYTES=$(STREAM_BYTES) \
		-Wa,--defsym,STREAM_VM=1 \
		-Wl,--build-id=none,-Map,$(STREAM_VM_MAP) \
		-T sw/stream/openrv64-stream-vm.ld -o $@ \
		sw/stream/stream_vm_boot.S sw/stream/stream.S

$(STREAM_VM_BIN): $(STREAM_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(STREAM_VM_MEMH): $(STREAM_VM_BIN)
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(STREAM_VM_MEMH_BYTES) --word-bytes 32

$(STREAM_VM_DISASM): $(STREAM_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(STORE_EXTENSION_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/store-extension/store_extension_sv39.S \
		sw/stream/stream_vm_boot.S sw/stream/openrv64-stream-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(STORE_EXTENSION_VM_MAP) \
		-T sw/stream/openrv64-stream-vm.ld -o $@ \
		sw/stream/stream_vm_boot.S \
		sw/store-extension/store_extension_sv39.S

$(STORE_EXTENSION_VM_BIN): $(STORE_EXTENSION_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(STORE_EXTENSION_VM_MEMH): $(STORE_EXTENSION_VM_BIN)
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(STORE_EXTENSION_VM_MEMH_BYTES) --word-bytes 32

$(STORE_EXTENSION_VM_DISASM): $(STORE_EXTENSION_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(A53_STREAM_ELF): $(OPENRV64_MAKEFILES) sw/arm_a53/stream_se.S \
		sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) -mcpu=cortex-a53 -mabi=lp64 -nostdlib -nostartfiles \
		-static -no-pie \
		-Wa,--defsym,STREAM_KERNEL=$(STREAM_KERNEL_ID) \
		-Wa,--defsym,STREAM_BYTES=$(STREAM_BYTES) \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_STREAM_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/stream_se.S

$(A53_STREAM_DISASM): $(A53_STREAM_ELF)
	$(AARCH64_OBJDUMP) -d $< > $@

$(STRIDE_ELF): $(OPENRV64_MAKEFILES) sw/stride/stride.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-Wa,--defsym,STRIDE_BYTES=$(STRIDE_BYTES) \
		-Wl,--build-id=none,-Map,$(STRIDE_MAP) \
		-T sw/openrv64.ld -o $@ sw/stride/stride.S

$(STRIDE_BIN): $(STRIDE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(STRIDE_DISASM): $(STRIDE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(STENCIL_ELF): $(OPENRV64_MAKEFILES) sw/stride/stencil5.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(STENCIL_MAP) \
		-T sw/openrv64.ld -o $@ sw/stride/stencil5.S

$(STENCIL_BIN): $(STENCIL_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(STENCIL_DISASM): $(STENCIL_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ICACHE_ELF): $(OPENRV64_MAKEFILES) sw/icache/icache.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_I_ASFLAGS) \
		-Wa,--defsym,ICACHE_PATTERN=$(ICACHE_PATTERN_ID) \
		-Wa,--defsym,ICACHE_BYTES=$(ICACHE_BYTES) \
		-Wl,--build-id=none,-Map,$(ICACHE_MAP) \
		-T sw/openrv64.ld -o $@ sw/icache/icache.S

$(ICACHE_BIN): $(ICACHE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ICACHE_DISASM): $(ICACHE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(LZ4_ELF): $(OPENRV64_MAKEFILES) sw/lz4/lz4_start.S sw/lz4/lz4.c \
		sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_CFLAGS) -nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map,$(LZ4_MAP) \
		-T sw/openrv64.ld -o $@ sw/lz4/lz4_start.S sw/lz4/lz4.c

$(LZ4_BIN): $(LZ4_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(LZ4_DISASM): $(LZ4_ELF)
	$(RISCV_OBJDUMP) -d -S -M no-aliases $< > $@

$(PREFETCH_VERILATOR_BUILD): tb/tb_top_axi_3p.sv rtl/openrv64_top_3p.v \
	$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
	mkdir -p $(PREFETCH_VERILATOR_DIR)
	$(VERILATOR) --binary --timing \
		--verilate-jobs 0 --build-jobs 0 \
		--output-split 20000 --output-split-cfuncs 2000 \
		-Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-GRAM_BYTES=16777216 -GRAM_ZERO_INIT_LINES=0 \
		-GBP_TYPE=$(AXI_3P_PERF_BP_TYPE) \
		-GBP_RAS_ENABLE=$(AXI_3P_PERF_BP_RAS_ENABLE) \
		-GBP_RAS_DEPTH=$(AXI_3P_PERF_BP_RAS_DEPTH) \
		-GBP_BIMODAL_ENTRIES=$(AXI_3P_PERF_BP_BIMODAL_ENTRIES) \
		-GBP_BIMODAL_COUNTER_BITS=$(AXI_3P_PERF_BP_BIMODAL_COUNTER_BITS) \
		-GBP_BIMODAL_UPDATE_DEPTH=$(AXI_3P_PERF_BP_BIMODAL_UPDATE_DEPTH) \
		-GBP_GSHARE_ENTRIES=$(AXI_3P_PERF_BP_GSHARE_ENTRIES) \
		-GBP_GSHARE_COUNTER_BITS=$(AXI_3P_PERF_BP_GSHARE_COUNTER_BITS) \
		-GBP_BTB_ENTRIES=$(AXI_3P_PERF_BP_BTB_ENTRIES) \
		-GBP_BTB_TAG_BITS=$(AXI_3P_PERF_BP_BTB_TAG_BITS) \
		-GBP_INFLIGHT_DEPTH=$(AXI_3P_PERF_BP_INFLIGHT_DEPTH) \
		-GRETIRE_DEPTH=$(AXI_3P_RETIRE_DEPTH) \
		-GCOMPLETION_FORWARD_MASK=$(AXI_3P_COMPLETION_FORWARD_MASK) \
		-GBRANCH_FORWARD_MASK=$(AXI_3P_BRANCH_FORWARD_MASK) \
		-GFULL_FORWARDING=$(AXI_3P_FULL_FORWARDING) \
		-GRELAX_WAW=$(AXI_3P_RELAX_WAW) \
		-GRELAX_HAZARDS=$(AXI_3P_RELAX_HAZARDS) \
		-GISSUE_WINDOW=$(AXI_3P_ISSUE_WINDOW) \
		-GSPECULATION_WINDOW=$(AXI_3P_SPECULATION_WINDOW) \
		-GPOSTED_STORES=$(AXI_3P_POSTED_STORES) \
		-GFREE_BRANCHES=$(AXI_3P_FREE_BRANCHES) \
		-GEQ_BRANCH_PAIRING=$(AXI_3P_EQ_BRANCH_PAIRING) \
		-GORACLE_BRANCHES=$(AXI_3P_ORACLE_BRANCHES) \
		-GFREE_L1_REFILLS=$(AXI_3P_FREE_L1_REFILLS) \
		-GFREE_L1I_REFILLS=$(AXI_3P_FREE_L1I_REFILLS) \
		-GFREE_L1D_REFILLS=$(AXI_3P_FREE_L1D_REFILLS) \
		-GFREELOADER=$(AXI_3P_FREELOADER) \
		-GFREELOADER_LATENCY=$(AXI_3P_FREELOADER_LATENCY) \
		-GL1D_PREFETCH_ENABLE=$(PREFETCH_L1D_ENABLE) \
		-GL1D_PREFETCH_MAX_STRIDE_LINES=$(PREFETCH_L1D_MAX_STRIDE_LINES) \
		-GL1D_PREFETCH_STREAMS=$(PREFETCH_L1D_STREAMS) \
		-GL1D_PREFETCH_DISTANCE=$(PREFETCH_L1D_DISTANCE) \
		-GL1D_PREFETCH_ADAPTIVE_ENABLE=$(PREFETCH_L1D_ADAPTIVE_ENABLE) \
		-GL1D_PREFETCH_MAX_DISTANCE=$(PREFETCH_L1D_MAX_DISTANCE) \
		-GL1D_PREFETCH_QUEUE_LINES=$(PREFETCH_L1D_QUEUE_LINES) \
		-GL1D_PREFETCH_OUTSTANDING=$(PREFETCH_L1D_OUTSTANDING) \
		-GL1D_PREFETCH_DEMAND_RESERVE=$(PREFETCH_L1D_DEMAND_RESERVE) \
		-GFETCH_ALT_LOOKASIDE=$(PREFETCH_FETCH_ALT_LOOKASIDE) \
		-Irtl --top-module tb_top_axi_3p \
		-Mdir $(PREFETCH_VERILATOR_DIR) -o prefetch_3p_axi_tb \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS) \
		tb/tb_top_axi_3p.sv
