# Aggregate prefetch benchmark and regression suites.

PERFORMANCE_CONFIDENCE_GATE ?= 1

sw-prefetch-benchmarks: sw-memcpy sw-stream-suite sw-stride-sweep \
	sw-stencil5 sw-icache-suite sw-lz4

bench-prefetch-suite:
	$(MAKE) bench-memcpy
	$(MAKE) bench-stream-suite
	$(MAKE) bench-stride-sweep
	$(MAKE) bench-stencil5
	$(MAKE) bench-icache-footprints
	$(MAKE) bench-icache-patterns
	$(MAKE) bench-lz4

# Default performance regression entry point.  Keep the prefetch-only suite
# independently callable, then add end-to-end Sv39 coverage through the
# production L1/CCX/L2/AXI/DDR3 hierarchy.
bench-performance-suite:
	$(MAKE) bench-prefetch-suite
	$(MAKE) sim-core-3p-ccx-l2-vm \
		CORE_3P_CCX_L2_CONFIDENCE_GATE=$(PERFORMANCE_CONFIDENCE_GATE)
	$(MAKE) bench-stream-ddr3-vm-suite \
		CORE_3P_CCX_L2_CONFIDENCE_GATE=$(PERFORMANCE_CONFIDENCE_GATE)
	$(MAKE) sim-stream-ddr3-vm-suite \
		CORE_3P_CCX_L2_CONFIDENCE_GATE=$(PERFORMANCE_CONFIDENCE_GATE)

sim-prefetch-checks:
	$(MAKE) sim-memcpy
	$(MAKE) sim-stream-suite
	$(MAKE) sim-stride STRIDE_BYTES=4096
	$(MAKE) sim-stencil5
	$(MAKE) sim-icache-patterns ICACHE_BYTES=4096
	$(MAKE) sim-lz4
