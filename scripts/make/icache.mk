# Instruction-cache footprint and control-flow workload targets.

sw-icache: $(ICACHE_ELF) $(ICACHE_BIN) $(ICACHE_DISASM)

sw-icache-suite:
	$(MAKE) sw-icache ICACHE_PATTERN=fallthrough ICACHE_BYTES=4096
	$(MAKE) sw-icache ICACHE_PATTERN=fallthrough ICACHE_BYTES=16384
	$(MAKE) sw-icache ICACHE_PATTERN=fallthrough ICACHE_BYTES=65536
	$(MAKE) sw-icache ICACHE_PATTERN=fallthrough ICACHE_BYTES=262144
	$(MAKE) sw-icache ICACHE_PATTERN=branch ICACHE_BYTES=4096
	$(MAKE) sw-icache ICACHE_PATTERN=branch ICACHE_BYTES=16384
	$(MAKE) sw-icache ICACHE_PATTERN=branch ICACHE_BYTES=65536
	$(MAKE) sw-icache ICACHE_PATTERN=branch ICACHE_BYTES=262144
	$(MAKE) sw-icache ICACHE_PATTERN=call ICACHE_BYTES=4096
	$(MAKE) sw-icache ICACHE_PATTERN=call ICACHE_BYTES=16384
	$(MAKE) sw-icache ICACHE_PATTERN=call ICACHE_BYTES=65536
	$(MAKE) sw-icache ICACHE_PATTERN=call ICACHE_BYTES=262144

bench-icache: $(ICACHE_ELF)
	test -n "$(ICACHE_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(ICACHE_ELF) \
		AXI_3P_PERF_BIN=sim/icache-$(ICACHE_TAG)-bench.bin \
		AXI_3P_PERF_MEMH=sim/icache-$(ICACHE_TAG)-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(ICACHE_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(ICACHE_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(ICACHE_MEMH_WORDS) +done_pc=$(ICACHE_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/icache-$(ICACHE_TAG)-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/icache-$(ICACHE_TAG)-bench-pipeline.txt

bench-icache-footprints:
	$(MAKE) bench-icache ICACHE_BYTES=4096
	$(MAKE) bench-icache ICACHE_BYTES=16384
	$(MAKE) bench-icache ICACHE_BYTES=65536
	$(MAKE) bench-icache ICACHE_BYTES=262144

bench-icache-patterns:
	$(MAKE) bench-icache ICACHE_PATTERN=fallthrough
	$(MAKE) bench-icache ICACHE_PATTERN=branch
	$(MAKE) bench-icache ICACHE_PATTERN=call

sim-icache: $(ICACHE_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(ICACHE_ELF) \
		AXI_3P_PERF_BIN=sim/icache-$(ICACHE_TAG)-check.bin \
		AXI_3P_PERF_MEMH=sim/icache-$(ICACHE_TAG)-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(ICACHE_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(ICACHE_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(ICACHE_MEMH_WORDS) +expect_a0=$(ICACHE_PASS)" \
		AXI_3P_TRACE_CSV=sim/icache-$(ICACHE_TAG)-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/icache-$(ICACHE_TAG)-check-pipeline.txt

sim-icache-patterns:
	$(MAKE) sim-icache ICACHE_PATTERN=fallthrough
	$(MAKE) sim-icache ICACHE_PATTERN=branch
	$(MAKE) sim-icache ICACHE_PATTERN=call
