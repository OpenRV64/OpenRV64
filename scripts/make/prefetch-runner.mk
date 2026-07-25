# Shared prefetch runner and phony declarations.

.PHONY: sw-stream sw-stream-suite bench-stream bench-stream-suite sim-stream \
	sim-stream-suite bench-stream-ddr3 sim-stream-ddr3 \
	bench-stream-ddr3-vm sim-stream-ddr3-vm \
	bench-stream-magic sim-stream-magic \
	sw-stream-a53-gem5 sim-stream-a53-gem5
.PHONY: sw-stride sw-stride-sweep bench-stride bench-stride-sweep sim-stride
.PHONY: sw-stencil5 bench-stencil5 sim-stencil5
.PHONY: sw-icache sw-icache-suite bench-icache bench-icache-footprints \
	bench-icache-patterns sim-icache sim-icache-patterns
.PHONY: sw-lz4 bench-lz4 sim-lz4 sw-prefetch-benchmarks \
	bench-prefetch-suite sim-prefetch-checks sim-prefetch-3p-perf

sim-prefetch-3p-perf: $(AXI_3P_PERF_MEMH)
ifeq ($(PREFETCH_ENGINE),verilator)
	$(MAKE) $(PREFETCH_VERILATOR_BUILD)
	mkdir -p $(dir $(AXI_3P_TRACE_CSV)) $(dir $(AXI_3P_TRACE_REPORT))
ifeq ($(AXI_3P_PERF_PIPELINE_TRACE),1)
	$(PREFETCH_VERILATOR_BUILD) +memh=$(AXI_3P_PERF_MEMH) \
		+max_cycles=$(AXI_3P_PERF_MAX_CYCLES) $(AXI_3P_PERF_ARGS) \
		+pipeline_trace=$(AXI_3P_TRACE_CSV)
	$(PYTHON) tools/pipeline_trace_3p.py $(AXI_3P_TRACE_CSV) \
		--output $(AXI_3P_TRACE_REPORT) $(AXI_3P_TRACE_RENDER_ARGS)
	@echo "raw 3P trace: $(AXI_3P_TRACE_CSV)"
	@echo "3P pipeline report: $(AXI_3P_TRACE_REPORT)"
else
	$(PREFETCH_VERILATOR_BUILD) +memh=$(AXI_3P_PERF_MEMH) \
		+max_cycles=$(AXI_3P_PERF_MAX_CYCLES) $(AXI_3P_PERF_ARGS) \
		+no_pipeline_trace
endif
else
	$(MAKE) -B sim-top-axi-3p-perf \
		AXI_3P_FETCH_ALT_LOOKASIDE=$(PREFETCH_FETCH_ALT_LOOKASIDE) \
		AXI_3P_PERF_L1D_PREFETCH_ENABLE=$(PREFETCH_L1D_ENABLE) \
		AXI_3P_PERF_L1D_PREFETCH_MAX_STRIDE_LINES=$(PREFETCH_L1D_MAX_STRIDE_LINES) \
		AXI_3P_PERF_L1D_PREFETCH_STREAMS=$(PREFETCH_L1D_STREAMS) \
		AXI_3P_PERF_L1D_PREFETCH_DISTANCE=$(PREFETCH_L1D_DISTANCE) \
		AXI_3P_PERF_L1D_PREFETCH_ADAPTIVE_ENABLE=$(PREFETCH_L1D_ADAPTIVE_ENABLE) \
		AXI_3P_PERF_L1D_PREFETCH_MAX_DISTANCE=$(PREFETCH_L1D_MAX_DISTANCE) \
		AXI_3P_PERF_L1D_PREFETCH_QUEUE_LINES=$(PREFETCH_L1D_QUEUE_LINES) \
		AXI_3P_PERF_L1D_PREFETCH_OUTSTANDING=$(PREFETCH_L1D_OUTSTANDING) \
		AXI_3P_PERF_L1D_PREFETCH_DEMAND_RESERVE=$(PREFETCH_L1D_DEMAND_RESERVE)
endif
