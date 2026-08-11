# SoC, platform, cache, interconnect, and MMU simulation targets.

sim-top: $(TOP_SIM_BUILD)
	vvp $(TOP_SIM_BUILD)

sim-platform: $(PLATFORM_SIM_BUILD)
	vvp $(PLATFORM_SIM_BUILD)

sim-reset-sequencer: $(RESET_SEQUENCER_SIM_BUILD)
	vvp $(RESET_SEQUENCER_SIM_BUILD)

sim-uart-firmware: $(UART_FIRMWARE_SIM_BUILD) $(UART_FIRMWARE_MEMH)
	vvp $(UART_FIRMWARE_SIM_BUILD) +memh=$(UART_FIRMWARE_MEMH)

sim-uart-firmware-perf: $(UART_FIRMWARE_MEMH)
	$(MAKE) -B $(UART_FIRMWARE_PERF_SIM_BUILD) \
		UART_PERF_BP_TYPE=$(UART_PERF_BP_TYPE) \
		UART_PERF_BP_RAS_ENABLE=$(UART_PERF_BP_RAS_ENABLE) \
		UART_PERF_BP_RAS_DEPTH=$(UART_PERF_BP_RAS_DEPTH)
	mkdir -p $(dir $(UART_PERF_TRACE_CSV)) \
		$(dir $(UART_PERF_TRACE_REPORT))
	vvp $(UART_FIRMWARE_PERF_SIM_BUILD) +memh=$(UART_FIRMWARE_MEMH) \
		+timeout_only +cycle-trace=$(UART_PERF_TRACE_CSV)
	$(PYTHON) tools/pipeline_trace.py $(UART_PERF_TRACE_CSV) \
		--output $(UART_PERF_TRACE_REPORT)
	@echo "raw 1P UART trace: $(UART_PERF_TRACE_CSV)"
	@echo "1P UART pipeline report: $(UART_PERF_TRACE_REPORT)"

sim-top-trace: $(TOP_SIM_BUILD)
	mkdir -p $(dir $(TRACE_CSV)) $(dir $(TRACE_REPORT))
	vvp $(TOP_SIM_BUILD) +cycle-trace=$(TRACE_CSV)
	$(PYTHON) tools/pipeline_trace.py $(TRACE_CSV) --output $(TRACE_REPORT)
	@echo "raw trace: $(TRACE_CSV)"
	@echo "pipeline report: $(TRACE_REPORT)"

sim-sw-trace: $(SW_TRACE_SIM_BUILD) $(SW_BIN)
	mkdir -p $(dir $(SW_TRACE_CSV)) $(dir $(SW_TRACE_REPORT))
	$(PYTHON) tools/bin2mem.py $(SW_BIN) $(SW_MEMH) --size 0x10000
	vvp $(SW_TRACE_SIM_BUILD) +memh=$(SW_MEMH) \
		+cycle-trace=$(SW_TRACE_CSV) $(SW_RUN_ARGS)
	$(PYTHON) tools/pipeline_trace.py $(SW_TRACE_CSV) --output $(SW_TRACE_REPORT)
	@echo "raw trace: $(SW_TRACE_CSV)"
	@echo "pipeline report: $(SW_TRACE_REPORT)"

trace-report:
	$(PYTHON) tools/pipeline_trace.py $(TRACE_CSV) --output $(TRACE_REPORT)
	@echo "pipeline report: $(TRACE_REPORT)"

sim-clint: $(CLINT_SIM_BUILD)
	vvp $(CLINT_SIM_BUILD)

sim-plic: $(PLIC_SIM_BUILD)
	vvp $(PLIC_SIM_BUILD)

sim-uart: $(UART_SIM_BUILD)
	vvp $(UART_SIM_BUILD)

sim-gpio: $(GPIO_SIM_BUILD)
	vvp $(GPIO_SIM_BUILD)

sim-timer: $(TIMER_SIM_BUILD)
	vvp $(TIMER_SIM_BUILD)

sim-rom: $(ROM_SIM_BUILD)
	vvp $(ROM_SIM_BUILD)

sim-memory: $(MEMORY_SIM_BUILD)
	vvp $(MEMORY_SIM_BUILD)

sim-mem-channel: $(MEM_CHANNEL_SIM_BUILD)
	vvp $(MEM_CHANNEL_SIM_BUILD)

sim-l2-axi-ddr3: $(L2_AXI_DDR3_SIM_BUILD)
	vvp $(L2_AXI_DDR3_SIM_BUILD)

sim-mesh-router: $(MESH_ROUTER_SIM_BUILD)
	vvp $(MESH_ROUTER_SIM_BUILD)

sim-soc-bus: $(SOC_BUS_SIM_BUILD)
	vvp $(SOC_BUS_SIM_BUILD)

sim-core-bus: $(CORE_BUS_SIM_BUILD)
	vvp $(CORE_BUS_SIM_BUILD)

sim-icx-protocol-1h: $(ICX_PROTOCOL_1H_SIM_BUILD)
	vvp $(ICX_PROTOCOL_1H_SIM_BUILD)

sim-icx-protocol-2h: $(ICX_PROTOCOL_2H_SIM_BUILD)
	vvp $(ICX_PROTOCOL_2H_SIM_BUILD)

sim-icx-protocol-4h: $(ICX_PROTOCOL_4H_SIM_BUILD)
	vvp $(ICX_PROTOCOL_4H_SIM_BUILD)

sim-icx-coherent-2h: $(ICX_COHERENT_2H_SIM_BUILD)
	vvp $(ICX_COHERENT_2H_SIM_BUILD)

sim-icx-coherent-4h: $(ICX_COHERENT_4H_SIM_BUILD)
	vvp $(ICX_COHERENT_4H_SIM_BUILD)

sim-icx-coherent-protocol-2h: $(ICX_COHERENT_PROTOCOL_2H_SIM_BUILD)
	vvp $(ICX_COHERENT_PROTOCOL_2H_SIM_BUILD)

sim-icx-coherent-protocol-4h: $(ICX_COHERENT_PROTOCOL_4H_SIM_BUILD)
	vvp $(ICX_COHERENT_PROTOCOL_4H_SIM_BUILD)

sim-icx-4h-l1d-directory-l2: $(ICX_4H_L1D_DIRECTORY_L2_SIM_BUILD)
	vvp $(ICX_4H_L1D_DIRECTORY_L2_SIM_BUILD)

sim-l1-cache: $(L1_CACHE_SIM_BUILD)
	vvp $(L1_CACHE_SIM_BUILD)

sim-l1-sync-tag: $(L1_SYNC_TAG_SIM_BUILD)
	vvp $(L1_SYNC_TAG_SIM_BUILD)

sim-l1-tag-mode-performance: $(L1_TAG_MODE_PERFORMANCE_SIM_BUILD)
	vvp $(L1_TAG_MODE_PERFORMANCE_SIM_BUILD)

sim-lsq-l1d-store-performance: $(LSQ_L1D_STORE_PERFORMANCE_SIM_BUILD)
	vvp $(LSQ_L1D_STORE_PERFORMANCE_SIM_BUILD)

sim-l1d-prefetch: $(L1D_PREFETCH_SIM_BUILD)
	vvp $(L1D_PREFETCH_SIM_BUILD)

sim-l1d-demand-mshr: $(L1D_DEMAND_MSHR_SIM_BUILD)
	vvp $(L1D_DEMAND_MSHR_SIM_BUILD)

sim-l1d-store-order: $(L1D_STORE_ORDER_SIM_BUILD)
	vvp $(L1D_STORE_ORDER_SIM_BUILD)

sim-l1d-store-buffer: $(L1D_STORE_BUFFER_SIM_BUILD)
	vvp $(L1D_STORE_BUFFER_SIM_BUILD)

sim-l1d-fence-behavior: $(L1D_FENCE_BEHAVIOR_SIM_BUILD)
	vvp $(L1D_FENCE_BEHAVIOR_SIM_BUILD)

sim-l1d-invalidate-arbiter: $(L1D_INVALIDATE_ARBITER_SIM_BUILD)
	vvp $(L1D_INVALIDATE_ARBITER_SIM_BUILD)

sim-icx-l2: $(ICX_L2_SIM_BUILD)
	vvp $(ICX_L2_SIM_BUILD)

sim-icx-l2-sc-refill: $(ICX_L2_SC_REFILL_SIM_BUILD)
	vvp $(ICX_L2_SC_REFILL_SIM_BUILD)

sim-genbus-axi: $(GENBUS_AXI_SIM_BUILD)
	vvp $(GENBUS_AXI_SIM_BUILD)

sim-genbus-wb: $(GENBUS_WB_SIM_BUILD)
	vvp $(GENBUS_WB_SIM_BUILD)

sim-genbus-wb-widths: $(GENBUS_WB_32_SIM_BUILD) \
		$(GENBUS_WB_SIM_BUILD) $(GENBUS_WB_128_SIM_BUILD) \
		$(GENBUS_WB_256_SIM_BUILD) $(GENBUS_WB_512_SIM_BUILD)
	vvp $(GENBUS_WB_32_SIM_BUILD)
	vvp $(GENBUS_WB_SIM_BUILD)
	vvp $(GENBUS_WB_128_SIM_BUILD)
	vvp $(GENBUS_WB_256_SIM_BUILD)
	vvp $(GENBUS_WB_512_SIM_BUILD)

sim-core-complex-1h-axi: $(CORE_COMPLEX_1H_AXI_SIM_BUILD)
	vvp $(CORE_COMPLEX_1H_AXI_SIM_BUILD)

sim-core-complex-2h-axi: $(CORE_COMPLEX_2H_AXI_SIM_BUILD)
	vvp $(CORE_COMPLEX_2H_AXI_SIM_BUILD)

sim-core-complex-4h-wb: $(CORE_COMPLEX_4H_WB_SIM_BUILD)
	vvp $(CORE_COMPLEX_4H_WB_SIM_BUILD)

sim-icx-bus: $(ICX_BUS_SIM_BUILD) $(ICX_L1I_SIM_BUILD)
	vvp $(ICX_BUS_SIM_BUILD)
	vvp $(ICX_L1I_SIM_BUILD)

sim-l1i-top: $(L1I_TOP_SIM_BUILD) $(L1I_COREMARK_MEMH)
	vvp $(L1I_TOP_SIM_BUILD) +memh=$(L1I_COREMARK_MEMH)

sim-tlb: $(TLB_SIM_BUILD)
	vvp $(TLB_SIM_BUILD)

sim-micro-tlb: $(MICRO_TLB_SIM_BUILD)
	vvp $(MICRO_TLB_SIM_BUILD)

sim-tlb-l2: $(TLB_L2_SIM_BUILD)
	vvp $(TLB_L2_SIM_BUILD)

sim-ptw: $(PTW_SIM_BUILD)
	vvp $(PTW_SIM_BUILD)

sim-ptw-context: $(PTW_CONTEXT_SIM_BUILD)
	vvp $(PTW_CONTEXT_SIM_BUILD)
