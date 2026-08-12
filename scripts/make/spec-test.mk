# Predictable-branch speculative issue microbenchmark.

SPEC_TEST_MISPRED_LOG2 ?= 0
SPEC_TEST_RETIRE_DEPTH ?= 32
SPEC_TEST_FIRST_BRANCH_SLOT ?= 6
SPEC_TEST_BUILD_DIR := \
	build/spec-test/branch-slot-$(SPEC_TEST_FIRST_BRANCH_SLOT)-mispred-log2-$(SPEC_TEST_MISPRED_LOG2)
SPEC_TEST_ELF := $(SPEC_TEST_BUILD_DIR)/spec_test.elf
SPEC_TEST_BIN := $(SPEC_TEST_BUILD_DIR)/spec_test.bin
SPEC_TEST_MEMH := $(SPEC_TEST_BUILD_DIR)/spec_test.memh
SPEC_TEST_MAP := $(SPEC_TEST_BUILD_DIR)/spec_test.map
SPEC_TEST_DISASM := $(SPEC_TEST_BUILD_DIR)/spec_test.disasm
SPEC_TEST_SRAM_BYTES := 65536
SPEC_TEST_MAX_CYCLES ?= 500000
SPEC_TEST_PASS := 53504543544f4b21
SPEC_TEST_ASFLAGS := -march=rv64ima_zicsr_zifencei -mabi=lp64 \
	-mcmodel=medany -mno-relax -nostdlib -nostartfiles \
	-DSPEC_TEST_MISPRED_LOG2=$(SPEC_TEST_MISPRED_LOG2) \
	-DSPEC_TEST_FIRST_BRANCH_SLOT=$(SPEC_TEST_FIRST_BRANCH_SLOT)

.PHONY: sw-spec-test bench-spec-test bench-spec-test-control \
	bench-spec-test-spec bench-spec-test-run bench-spec-test-two-branch

$(SPEC_TEST_ELF): $(OPENRV64_MAKEFILES) sw/spec_test/spec_test.S \
		sw/runtime/bare.S sw/runtime/c_start.inc sw/openrv64-magic.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(SPEC_TEST_ASFLAGS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(SPEC_TEST_MAP) \
		-T sw/openrv64-magic.ld -o $@ sw/runtime/bare.S \
		sw/spec_test/spec_test.S

$(SPEC_TEST_BIN): $(SPEC_TEST_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(SPEC_TEST_MEMH): $(SPEC_TEST_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(SPEC_TEST_SRAM_BYTES) --word-bytes 32

$(SPEC_TEST_DISASM): $(SPEC_TEST_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

sw-spec-test: $(SPEC_TEST_ELF) $(SPEC_TEST_BIN) $(SPEC_TEST_MEMH) \
		$(SPEC_TEST_DISASM)

# Invoke with "make -j2 bench-spec-test" to build/run both hardware controls
# concurrently.  Both runs consume the exact same software image.
bench-spec-test: bench-spec-test-control bench-spec-test-spec

bench-spec-test-two-branch:
	$(MAKE) bench-spec-test \
		SPEC_TEST_FIRST_BRANCH_SLOT=16 \
		SPEC_TEST_RETIRE_DEPTH=$(SPEC_TEST_RETIRE_DEPTH) \
		SPEC_TEST_MISPRED_LOG2=$(SPEC_TEST_MISPRED_LOG2)

bench-spec-test-control: $(SPEC_TEST_MEMH)
	$(MAKE) bench-spec-test-run \
		CORE_3P_MAGIC_BP_TYPE=8 \
		CORE_3P_MAGIC_MODE=3 \
		CORE_3P_MAGIC_CONFIDENCE_GATE=0 \
		CORE_3P_MAGIC_ISSUE_WINDOW=1 \
		CORE_3P_MAGIC_SPECULATION_WINDOW=0 \
		CORE_3P_MAGIC_RETIRE_DEPTH=$(SPEC_TEST_RETIRE_DEPTH) \
		SPEC_TEST_FIRST_BRANCH_SLOT=$(SPEC_TEST_FIRST_BRANCH_SLOT) \
		SPEC_TEST_MISPRED_LOG2=$(SPEC_TEST_MISPRED_LOG2)

bench-spec-test-spec: $(SPEC_TEST_MEMH)
	$(MAKE) bench-spec-test-run \
		CORE_3P_MAGIC_BP_TYPE=8 \
		CORE_3P_MAGIC_MODE=3 \
		CORE_3P_MAGIC_CONFIDENCE_GATE=0 \
		CORE_3P_MAGIC_ISSUE_WINDOW=1 \
		CORE_3P_MAGIC_SPECULATION_WINDOW=1 \
		CORE_3P_MAGIC_RETIRE_DEPTH=$(SPEC_TEST_RETIRE_DEPTH) \
		SPEC_TEST_FIRST_BRANCH_SLOT=$(SPEC_TEST_FIRST_BRANCH_SLOT) \
		SPEC_TEST_MISPRED_LOG2=$(SPEC_TEST_MISPRED_LOG2)

bench-spec-test-run: $(CORE_3P_MAGIC_VERILATOR_BUILD) $(SPEC_TEST_MEMH)
	$(CORE_3P_MAGIC_VERILATOR_BUILD) \
		+memh=$(abspath $(SPEC_TEST_MEMH)) \
		+max_cycles=$(SPEC_TEST_MAX_CYCLES) \
		+expect_a0=$(SPEC_TEST_PASS)
