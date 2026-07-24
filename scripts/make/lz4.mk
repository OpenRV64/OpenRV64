# LZ4 workload targets.

sw-lz4: $(LZ4_ELF) $(LZ4_BIN) $(LZ4_DISASM)

bench-lz4: $(LZ4_ELF)
	test -n "$(LZ4_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(LZ4_ELF) \
		AXI_3P_PERF_BIN=sim/lz4-bench.bin \
		AXI_3P_PERF_MEMH=sim/lz4-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(LZ4_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(LZ4_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(LZ4_MEMH_WORDS) +done_pc=$(LZ4_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/lz4-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/lz4-bench-pipeline.txt

sim-lz4: $(LZ4_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(LZ4_ELF) \
		AXI_3P_PERF_BIN=sim/lz4-check.bin \
		AXI_3P_PERF_MEMH=sim/lz4-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(LZ4_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(LZ4_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(LZ4_MEMH_WORDS) +expect_a0=$(LZ4_PASS)" \
		AXI_3P_TRACE_CSV=sim/lz4-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/lz4-check-pipeline.txt
