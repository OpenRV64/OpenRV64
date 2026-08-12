# Linux generic BLAKE2s compression microbenchmark.

BLAKE2S_CALLS ?= 16
BLAKE2S_BLOCKS_PER_CALL ?= 1

ifeq ($(filter $(BLAKE2S_CALLS),1 4 16 64),)
$(error BLAKE2S_CALLS must be 1, 4, 16, or 64)
endif
ifeq ($(filter $(BLAKE2S_BLOCKS_PER_CALL),1 2 4 8 16),)
$(error BLAKE2S_BLOCKS_PER_CALL must be 1, 2, 4, 8, or 16)
endif

BLAKE2S_TAG := c$(BLAKE2S_CALLS)-b$(BLAKE2S_BLOCKS_PER_CALL)
BLAKE2S_BUILD_DIR := build/blake2s/$(BLAKE2S_TAG)
BLAKE2S_ELF := $(BLAKE2S_BUILD_DIR)/blake2s.elf
BLAKE2S_BIN := $(BLAKE2S_BUILD_DIR)/blake2s.bin
BLAKE2S_MEMH := $(BLAKE2S_BUILD_DIR)/blake2s.memh
BLAKE2S_MAP := $(BLAKE2S_BUILD_DIR)/blake2s.map
BLAKE2S_DISASM := $(BLAKE2S_BUILD_DIR)/blake2s.disasm
BLAKE2S_VM_ELF := $(BLAKE2S_BUILD_DIR)/blake2s-sv39.elf
BLAKE2S_VM_BIN := $(BLAKE2S_BUILD_DIR)/blake2s-sv39.bin
BLAKE2S_VM_MEMH := $(BLAKE2S_BUILD_DIR)/blake2s-sv39.memh
BLAKE2S_VM_MAP := $(BLAKE2S_BUILD_DIR)/blake2s-sv39.map
BLAKE2S_VM_DISASM := $(BLAKE2S_BUILD_DIR)/blake2s-sv39.disasm
A53_BLAKE2S_ELF := $(BLAKE2S_BUILD_DIR)/blake2s-a53-se.elf
A53_BLAKE2S_MAP := $(BLAKE2S_BUILD_DIR)/blake2s-a53-se.map
A53_BLAKE2S_DISASM := $(BLAKE2S_BUILD_DIR)/blake2s-a53-se.disasm
A53_BLAKE2S_OUTDIR ?= sim/a53/gem5-hpi-blake2s-$(BLAKE2S_TAG)
A53_BLAKE2S_STATS := $(A53_BLAKE2S_OUTDIR)/stats.txt
A53_BLAKE2S_REPORT := $(A53_BLAKE2S_OUTDIR)/report.txt
BLAKE2S_IMAGE_BYTES := 131072
BLAKE2S_MEMH_WORDS := 4096
BLAKE2S_VM_IMAGE_BYTES := 0x44000
BLAKE2S_VM_MEMH_WORDS := 8704
BLAKE2S_MAX_CYCLES ?= 2000000
BLAKE2S_PROGRESS_CYCLES ?= 250000
BLAKE2S_PASS := 424c414b45324f4b
BLAKE2S_DDR3 ?= 0
BLAKE2S_MEMORY_TIMING_MODEL ?= 0
BLAKE2S_DDR3_BANK_ROW_SWIZZLE ?= 0
BLAKE2S_REQUIRE_ARGS ?=
BLAKE2S_MEASURE_END = $(shell $(RISCV_NM) -n $(BLAKE2S_ELF) | \
	awk '$$3 == "blake2s_measure_end" { print $$1 }')
BLAKE2S_VM_MEASURE_END = $(shell $(RISCV_NM) -n $(BLAKE2S_VM_ELF) | \
	awk '$$3 == "blake2s_measure_end" { print $$1 }')
BLAKE2S_VM_DONE = $(shell $(RISCV_NM) -n $(BLAKE2S_VM_ELF) | \
	awk '$$3 == "openrv64_runtime_done" { print $$1 }')
BLAKE2S_COMPRESS_SIZE = $(shell $(RISCV_NM) -S --size-sort \
	$(BLAKE2S_ELF) | awk '$$4 == "blake2s_compress_generic" { print $$2 }')

.PHONY: sw-blake2s sw-blake2s-sv39 sim-blake2s sim-blake2s-ddr3 \
	sim-blake2s-sv39 bench-blake2s bench-blake2s-ddr3 \
	bench-blake2s-sv39 sw-blake2s-a53-gem5 sim-blake2s-a53-gem5

$(BLAKE2S_ELF): $(OPENRV64_MAKEFILES) \
		sw/runtime/bare.S sw/runtime/c_start.inc \
		sw/blake2s/blake2s_start.S sw/blake2s/blake2s.c sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_CFLAGS) -fno-strict-overflow \
		-fconserve-stack -mstrict-align -nostdlib -nostartfiles \
		-DBLAKE2S_BENCH_CALLS=$(BLAKE2S_CALLS) \
		-DBLAKE2S_BLOCKS_PER_CALL=$(BLAKE2S_BLOCKS_PER_CALL) \
		-Wl,--build-id=none,-Map,$(BLAKE2S_MAP) \
		-T sw/openrv64.ld -o $@ \
		sw/runtime/bare.S sw/blake2s/blake2s_start.S \
		sw/blake2s/blake2s.c

$(BLAKE2S_BIN): $(BLAKE2S_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(BLAKE2S_MEMH): $(BLAKE2S_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(BLAKE2S_IMAGE_BYTES) --word-bytes 32

$(BLAKE2S_DISASM): $(BLAKE2S_ELF)
	$(RISCV_OBJDUMP) -d -S -M no-aliases $< > $@

$(BLAKE2S_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/runtime/sv39.S sw/runtime/c_start.inc \
		sw/runtime/openrv64-sv39.ld sw/blake2s/blake2s_start.S \
		sw/blake2s/blake2s.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_CFLAGS) -fno-strict-overflow \
		-fconserve-stack -mstrict-align -nostdlib -nostartfiles \
		-DBLAKE2S_BENCH_CALLS=$(BLAKE2S_CALLS) \
		-DBLAKE2S_BLOCKS_PER_CALL=$(BLAKE2S_BLOCKS_PER_CALL) \
		-Wl,--build-id=none,-Map,$(BLAKE2S_VM_MAP) \
		-T sw/runtime/openrv64-sv39.ld -o $@ \
		sw/runtime/sv39.S \
		sw/blake2s/blake2s_start.S sw/blake2s/blake2s.c

$(BLAKE2S_VM_BIN): $(BLAKE2S_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(BLAKE2S_VM_MEMH): $(BLAKE2S_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(BLAKE2S_VM_IMAGE_BYTES) --word-bytes 32

$(BLAKE2S_VM_DISASM): $(BLAKE2S_VM_ELF)
	$(RISCV_OBJDUMP) -d -S -M no-aliases $< > $@

$(A53_BLAKE2S_ELF): $(OPENRV64_MAKEFILES) \
		sw/arm_a53/blake2s_se_start.S sw/blake2s/blake2s.c \
		sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) -mcpu=cortex-a53 -mabi=lp64 -O2 -g -Wall \
		-Wextra -Werror -ffreestanding -fno-builtin -fno-common \
		-fno-pic -fno-stack-protector -fno-asynchronous-unwind-tables \
		-fno-strict-overflow -fconserve-stack -mstrict-align \
		-nostdlib -nostartfiles -static -no-pie \
		-DBLAKE2S_BENCH_CALLS=$(BLAKE2S_CALLS) \
		-DBLAKE2S_BLOCKS_PER_CALL=$(BLAKE2S_BLOCKS_PER_CALL) \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_BLAKE2S_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/blake2s_se_start.S sw/blake2s/blake2s.c

$(A53_BLAKE2S_DISASM): $(A53_BLAKE2S_ELF)
	$(AARCH64_OBJDUMP) -d $< > $@

sw-blake2s: $(BLAKE2S_ELF) $(BLAKE2S_BIN) $(BLAKE2S_MEMH) \
		$(BLAKE2S_DISASM)
	@echo "BLAKE2s generic compression size: 0x$(BLAKE2S_COMPRESS_SIZE) bytes"

sw-blake2s-sv39: $(BLAKE2S_VM_ELF) $(BLAKE2S_VM_BIN) \
		$(BLAKE2S_VM_MEMH) $(BLAKE2S_VM_DISASM)

sw-blake2s-a53-gem5: $(A53_BLAKE2S_ELF) $(A53_BLAKE2S_DISASM)

sim-blake2s: $(BLAKE2S_MEMH)
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BLAKE2S_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BLAKE2S_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(BLAKE2S_PASS) +progress_cycles=$(BLAKE2S_PROGRESS_CYCLES) $(BLAKE2S_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BLAKE2S_MAX_CYCLES) \
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
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=$(BLAKE2S_DDR3) \
		CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE=$(BLAKE2S_DDR3_BANK_ROW_SWIZZLE) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(BLAKE2S_MEMORY_TIMING_MODEL)

bench-blake2s: $(BLAKE2S_MEMH)
	test -n "$(BLAKE2S_MEASURE_END)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BLAKE2S_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BLAKE2S_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(BLAKE2S_MEASURE_END) +report_blake2s +progress_cycles=$(BLAKE2S_PROGRESS_CYCLES) $(BLAKE2S_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BLAKE2S_MAX_CYCLES) \
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
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=$(BLAKE2S_DDR3) \
		CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE=$(BLAKE2S_DDR3_BANK_ROW_SWIZZLE) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(BLAKE2S_MEMORY_TIMING_MODEL)

sim-blake2s-ddr3:
	$(MAKE) sim-blake2s BLAKE2S_DDR3=1 \
		BLAKE2S_REQUIRE_ARGS=+require_timed_memory

bench-blake2s-ddr3:
	$(MAKE) bench-blake2s BLAKE2S_DDR3=1 \
		BLAKE2S_REQUIRE_ARGS=+require_timed_memory

sim-blake2s-sv39: $(BLAKE2S_VM_MEMH)
	test -n "$(BLAKE2S_VM_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BLAKE2S_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BLAKE2S_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(BLAKE2S_PASS) +done_pc=$(BLAKE2S_VM_DONE) +require_sv39 +require_timed_memory" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BLAKE2S_MAX_CYCLES) \
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
		CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE=0 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE=$(BLAKE2S_DDR3_BANK_ROW_SWIZZLE) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(BLAKE2S_MEMORY_TIMING_MODEL)

bench-blake2s-sv39: $(BLAKE2S_VM_MEMH)
	test -n "$(BLAKE2S_VM_MEASURE_END)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BLAKE2S_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BLAKE2S_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(BLAKE2S_VM_MEASURE_END) +report_blake2s +require_sv39 +require_timed_memory" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BLAKE2S_MAX_CYCLES) \
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
		CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE=0 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE=$(BLAKE2S_DDR3_BANK_ROW_SWIZZLE) \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=$(BLAKE2S_MEMORY_TIMING_MODEL)

sim-blake2s-a53-gem5: sw-blake2s-a53-gem5
	test -x $(GEM5_AARCH64)
	test -f $(GEM5_A53_CONFIG)
	$(GEM5_AARCH64) -d $(A53_BLAKE2S_OUTDIR) \
		$(GEM5_A53_CONFIG) --cpu=hpi --cpu-freq=1GHz \
		--num-cores=1 --mem-type=DDR3_1600_8x8 --mem-channels=1 \
		--mem-size=128MiB \
		-P 'system.cpu_cluster.cpus[0].enableIdling=False' \
		$(abspath $(A53_BLAKE2S_ELF))
	$(PYTHON) tools/gem5_hpi_blake2s_report.py $(A53_BLAKE2S_STATS) \
		--calls $(BLAKE2S_CALLS) \
		--blocks-per-call $(BLAKE2S_BLOCKS_PER_CALL) \
		--output $(A53_BLAKE2S_REPORT)
