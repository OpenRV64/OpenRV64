# Linux struct-page freeing-loop microbenchmark.

PAGEFREE_KERNEL ?= core
PAGEFREE_QUICK_RECORDS ?= 8192
PAGEFREE_FULL_RECORDS ?= 65536
PAGEFREE_RECORDS ?= $(PAGEFREE_QUICK_RECORDS)
PAGEFREE_KERNEL_ID := $(strip $(if $(filter core,$(PAGEFREE_KERNEL)),0,\
	$(if $(filter tail,$(PAGEFREE_KERNEL)),1,\
	$(if $(filter buddy,$(PAGEFREE_KERNEL)),2,))))
ifeq ($(PAGEFREE_KERNEL_ID),)
$(error PAGEFREE_KERNEL must be core, tail, or buddy)
endif
ifeq ($(filter $(PAGEFREE_RECORDS),1024 4096 8192 16384 65536),)
$(error PAGEFREE_RECORDS must be 1024, 4096, 8192, 16384, or 65536)
endif

PAGEFREE_TAG := $(PAGEFREE_KERNEL)-$(PAGEFREE_RECORDS)
PAGEFREE_BUILD_DIR := build/pagefree/$(PAGEFREE_TAG)
PAGEFREE_ELF := $(PAGEFREE_BUILD_DIR)/pagefree.elf
PAGEFREE_BIN := $(PAGEFREE_BUILD_DIR)/pagefree.bin
PAGEFREE_MEMH := $(PAGEFREE_BUILD_DIR)/pagefree.memh
PAGEFREE_MAP := $(PAGEFREE_BUILD_DIR)/pagefree.map
PAGEFREE_DISASM := $(PAGEFREE_BUILD_DIR)/pagefree.disasm
PAGEFREE_IMAGE_BYTES ?= 5242880
PAGEFREE_MEMH_WORDS := 163840
PAGEFREE_MAX_CYCLES ?= 20000000
PAGEFREE_PROGRESS_CYCLES ?= 1000000
PAGEFREE_PASS := 5041474546524545
PAGEFREE_DDR3 ?= 0
PAGEFREE_MEMORY_TIMING_MODEL ?= 0
PAGEFREE_L1D_PREFETCH_ENABLE ?= 1
PAGEFREE_L1D_PREFETCH_MAX_DISTANCE ?= 4
PAGEFREE_L1D_PREFETCH_PAGE_GATING ?= 1
PAGEFREE_REQUIRE_ARGS ?=
PAGEFREE_ASFLAGS := $(if $(filter buddy,$(PAGEFREE_KERNEL)),\
	-march=rv64ia_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
	-mno-relax -nostdlib -nostartfiles,$(PREFETCH_I_ASFLAGS))
A53_PAGEFREE_ELF := sim/a53/pagefree-$(PAGEFREE_TAG)-se.elf
A53_PAGEFREE_MAP := sim/a53/pagefree-$(PAGEFREE_TAG)-se.map
A53_PAGEFREE_DISASM := sim/a53/pagefree-$(PAGEFREE_TAG)-se.disasm
A53_PAGEFREE_OUTDIR ?= sim/a53/gem5-hpi-pagefree-$(PAGEFREE_TAG)
A53_PAGEFREE_STATS := $(A53_PAGEFREE_OUTDIR)/stats.txt
A53_PAGEFREE_REPORT := $(A53_PAGEFREE_OUTDIR)/report.txt
PAGEFREE_MEASURE_END = $(shell $(RISCV_NM) -n $(PAGEFREE_ELF) | \
	awk '$$3 == "pagefree_drain_end" { print $$1 }')
PAGEFREE_DONE = $(shell $(RISCV_NM) -n $(PAGEFREE_ELF) | \
	awk '$$3 == "pagefree_done" { print $$1 }')

.PHONY: sw-pagefree sw-pagefree-suite sim-pagefree sim-pagefree-suite \
	sim-pagefree-full sim-pagefree-full-suite \
	bench-pagefree bench-pagefree-suite sim-pagefree-ddr3 \
	sim-pagefree-ddr3-suite bench-pagefree-ddr3 \
	bench-pagefree-ddr3-suite bench-pagefree-full \
	bench-pagefree-full-suite bench-pagefree-ddr3-full \
	bench-pagefree-ddr3-full-suite sw-pagefree-a53-gem5 \
	sim-pagefree-a53-gem5 sim-pagefree-a53-gem5-suite \
	sim-pagefree-a53-gem5-full-suite

$(PAGEFREE_ELF): $(OPENRV64_MAKEFILES) sw/pagefree/pagefree.S \
		sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PAGEFREE_ASFLAGS) \
		-Wa,--defsym,PAGEFREE_KERNEL=$(PAGEFREE_KERNEL_ID) \
		-Wa,--defsym,PAGEFREE_RECORDS=$(PAGEFREE_RECORDS) \
		-Wl,--build-id=none,-Map,$(PAGEFREE_MAP) \
		-T sw/openrv64.ld -o $@ sw/pagefree/pagefree.S

$(PAGEFREE_BIN): $(PAGEFREE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(PAGEFREE_MEMH): $(PAGEFREE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(PAGEFREE_IMAGE_BYTES) --word-bytes 32

$(PAGEFREE_DISASM): $(PAGEFREE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(A53_PAGEFREE_ELF): $(OPENRV64_MAKEFILES) \
		sw/arm_a53/pagefree_se.S sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) -mcpu=cortex-a53 -mabi=lp64 -nostdlib -nostartfiles \
		-static -no-pie \
		-Wa,--defsym,PAGEFREE_KERNEL=$(PAGEFREE_KERNEL_ID) \
		-Wa,--defsym,PAGEFREE_RECORDS=$(PAGEFREE_RECORDS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_PAGEFREE_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/pagefree_se.S

$(A53_PAGEFREE_DISASM): $(A53_PAGEFREE_ELF)
	$(AARCH64_OBJDUMP) -d $< > $@

sw-pagefree: $(PAGEFREE_ELF) $(PAGEFREE_BIN) $(PAGEFREE_MEMH) \
		$(PAGEFREE_DISASM)

sw-pagefree-a53-gem5: $(A53_PAGEFREE_ELF) $(A53_PAGEFREE_DISASM)

sw-pagefree-suite:
	$(MAKE) sw-pagefree PAGEFREE_KERNEL=core \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) sw-pagefree PAGEFREE_KERNEL=tail \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) sw-pagefree PAGEFREE_KERNEL=buddy \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)

sim-pagefree: $(PAGEFREE_MEMH)
	test -n "$(PAGEFREE_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(PAGEFREE_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(PAGEFREE_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(PAGEFREE_PASS) +done_pc=$(PAGEFREE_DONE) +progress_cycles=$(PAGEFREE_PROGRESS_CYCLES) $(PAGEFREE_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(PAGEFREE_MAX_CYCLES) \
		CORE_3P_ICX_L2_RAM_BYTES=16777216 \
		CORE_3P_ICX_L2_BP_TYPE=8 \
		CORE_3P_ICX_L2_FETCH_CAROUSEL=1 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_CONFIDENCE_GATE=0 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=32 \
		CORE_3P_ICX_L2_PHYS_REG_COUNT=31 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=$(PAGEFREE_L1D_PREFETCH_ENABLE) \
		CORE_3P_ICX_L2_L1D_PREFETCH_MAX_DISTANCE=$(PAGEFREE_L1D_PREFETCH_MAX_DISTANCE) \
		CORE_3P_ICX_L2_L1D_PREFETCH_PAGE_GATING=$(PAGEFREE_L1D_PREFETCH_PAGE_GATING) \
		CORE_3P_ICX_L2_DDR3=$(PAGEFREE_DDR3) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(PAGEFREE_MEMORY_TIMING_MODEL)

sim-pagefree-suite:
	$(MAKE) sim-pagefree PAGEFREE_KERNEL=core \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) sim-pagefree PAGEFREE_KERNEL=tail \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) sim-pagefree PAGEFREE_KERNEL=buddy \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)

sim-pagefree-full:
	$(MAKE) sim-pagefree PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

sim-pagefree-full-suite:
	$(MAKE) sim-pagefree-suite PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

bench-pagefree: $(PAGEFREE_MEMH)
	test -n "$(PAGEFREE_MEASURE_END)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(PAGEFREE_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(PAGEFREE_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(PAGEFREE_MEASURE_END) +report_pagefree +progress_cycles=$(PAGEFREE_PROGRESS_CYCLES) $(PAGEFREE_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(PAGEFREE_MAX_CYCLES) \
		CORE_3P_ICX_L2_RAM_BYTES=16777216 \
		CORE_3P_ICX_L2_BP_TYPE=8 \
		CORE_3P_ICX_L2_FETCH_CAROUSEL=1 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_CONFIDENCE_GATE=0 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=32 \
		CORE_3P_ICX_L2_PHYS_REG_COUNT=31 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=$(PAGEFREE_L1D_PREFETCH_ENABLE) \
		CORE_3P_ICX_L2_L1D_PREFETCH_MAX_DISTANCE=$(PAGEFREE_L1D_PREFETCH_MAX_DISTANCE) \
		CORE_3P_ICX_L2_L1D_PREFETCH_PAGE_GATING=$(PAGEFREE_L1D_PREFETCH_PAGE_GATING) \
		CORE_3P_ICX_L2_DDR3=$(PAGEFREE_DDR3) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(PAGEFREE_MEMORY_TIMING_MODEL)

bench-pagefree-suite:
	$(MAKE) bench-pagefree PAGEFREE_KERNEL=core \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) bench-pagefree PAGEFREE_KERNEL=tail \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) bench-pagefree PAGEFREE_KERNEL=buddy \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)

bench-pagefree-full:
	$(MAKE) bench-pagefree PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

bench-pagefree-full-suite:
	$(MAKE) bench-pagefree-suite PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

sim-pagefree-ddr3:
	$(MAKE) sim-pagefree PAGEFREE_DDR3=1 \
		PAGEFREE_REQUIRE_ARGS=+require_timed_memory

sim-pagefree-ddr3-suite:
	$(MAKE) sim-pagefree-suite PAGEFREE_DDR3=1 \
		PAGEFREE_REQUIRE_ARGS=+require_timed_memory

bench-pagefree-ddr3:
	$(MAKE) bench-pagefree PAGEFREE_DDR3=1 \
		PAGEFREE_REQUIRE_ARGS=+require_timed_memory

bench-pagefree-ddr3-suite:
	$(MAKE) bench-pagefree-suite PAGEFREE_DDR3=1 \
		PAGEFREE_REQUIRE_ARGS=+require_timed_memory

bench-pagefree-ddr3-full:
	$(MAKE) bench-pagefree-ddr3 PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

bench-pagefree-ddr3-full-suite:
	$(MAKE) bench-pagefree-ddr3-suite \
		PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)

sim-pagefree-a53-gem5: sw-pagefree-a53-gem5
	test -x $(GEM5_AARCH64)
	test -f $(GEM5_A53_CONFIG)
	$(GEM5_AARCH64) -d $(A53_PAGEFREE_OUTDIR) \
		$(GEM5_A53_CONFIG) --cpu=hpi --cpu-freq=1GHz \
		--num-cores=1 --mem-type=DDR3_1600_8x8 --mem-channels=1 \
		--mem-size=128MiB \
		-P 'system.cpu_cluster.cpus[0].enableIdling=False' \
		$(abspath $(A53_PAGEFREE_ELF))
	$(PYTHON) tools/gem5_hpi_pagefree_report.py \
		$(A53_PAGEFREE_STATS) --kernel $(PAGEFREE_KERNEL) \
		--records $(PAGEFREE_RECORDS) --output $(A53_PAGEFREE_REPORT)

sim-pagefree-a53-gem5-suite:
	$(MAKE) sim-pagefree-a53-gem5 PAGEFREE_KERNEL=core \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)
	$(MAKE) sim-pagefree-a53-gem5 PAGEFREE_KERNEL=tail \
		PAGEFREE_RECORDS=$(PAGEFREE_RECORDS)

sim-pagefree-a53-gem5-full-suite:
	$(MAKE) sim-pagefree-a53-gem5-suite \
		PAGEFREE_RECORDS=$(PAGEFREE_FULL_RECORDS)
