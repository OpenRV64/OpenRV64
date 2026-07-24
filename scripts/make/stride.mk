# Stride-sweep and stencil workload targets.

sw-stride: $(STRIDE_ELF) $(STRIDE_BIN) $(STRIDE_DISASM)

sw-stride-sweep:
	$(MAKE) sw-stride STRIDE_BYTES=64
	$(MAKE) sw-stride STRIDE_BYTES=128
	$(MAKE) sw-stride STRIDE_BYTES=256
	$(MAKE) sw-stride STRIDE_BYTES=1024
	$(MAKE) sw-stride STRIDE_BYTES=4096

bench-stride: $(STRIDE_ELF)
	test -n "$(STRIDE_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(STRIDE_ELF) \
		AXI_3P_PERF_BIN=sim/stride-$(STRIDE_BYTES)-bench.bin \
		AXI_3P_PERF_MEMH=sim/stride-$(STRIDE_BYTES)-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(STRIDE_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(STRIDE_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(STRIDE_MEMH_WORDS) +done_pc=$(STRIDE_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/stride-$(STRIDE_BYTES)-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/stride-$(STRIDE_BYTES)-bench-pipeline.txt

bench-stride-sweep:
	$(MAKE) bench-stride STRIDE_BYTES=64
	$(MAKE) bench-stride STRIDE_BYTES=128
	$(MAKE) bench-stride STRIDE_BYTES=256
	$(MAKE) bench-stride STRIDE_BYTES=1024
	$(MAKE) bench-stride STRIDE_BYTES=4096

sim-stride: $(STRIDE_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(STRIDE_ELF) \
		AXI_3P_PERF_BIN=sim/stride-$(STRIDE_BYTES)-check.bin \
		AXI_3P_PERF_MEMH=sim/stride-$(STRIDE_BYTES)-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(STRIDE_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(STRIDE_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(STRIDE_MEMH_WORDS) +expect_a0=$(STRIDE_PASS)" \
		AXI_3P_TRACE_CSV=sim/stride-$(STRIDE_BYTES)-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/stride-$(STRIDE_BYTES)-check-pipeline.txt

sw-stencil5: $(STENCIL_ELF) $(STENCIL_BIN) $(STENCIL_DISASM)

bench-stencil5: $(STENCIL_ELF)
	test -n "$(STENCIL_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(STENCIL_ELF) \
		AXI_3P_PERF_BIN=sim/stencil5-bench.bin \
		AXI_3P_PERF_MEMH=sim/stencil5-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(STENCIL_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(STENCIL_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(STENCIL_MEMH_WORDS) +done_pc=$(STENCIL_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/stencil5-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/stencil5-bench-pipeline.txt

sim-stencil5: $(STENCIL_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(STENCIL_ELF) \
		AXI_3P_PERF_BIN=sim/stencil5-check.bin \
		AXI_3P_PERF_MEMH=sim/stencil5-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(STENCIL_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(STENCIL_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(STENCIL_MEMH_WORDS) +expect_a0=$(STENCIL_PASS)" \
		AXI_3P_TRACE_CSV=sim/stencil5-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/stencil5-check-pipeline.txt
