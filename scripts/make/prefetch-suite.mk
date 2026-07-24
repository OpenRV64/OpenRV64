# Aggregate prefetch benchmark and regression suites.

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

sim-prefetch-checks:
	$(MAKE) sim-memcpy
	$(MAKE) sim-stream-suite
	$(MAKE) sim-stride STRIDE_BYTES=4096
	$(MAKE) sim-stencil5
	$(MAKE) sim-icache-patterns ICACHE_BYTES=4096
	$(MAKE) sim-lz4
