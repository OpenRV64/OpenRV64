# Sv39 ordinary-fence correctness, microbenchmark, and atomic suite.

FENCE_BUILD_DIR := build/fence
FENCE_SV39_LD := sw/fence/openrv64-fence-sv39.ld
FENCE_SV39_BOOT := sw/fence/sv39_boot.S
FENCE_MEMH_BYTES := 0x44000
FENCE_MEMH_WORDS := 8704
FENCE_MAX_CYCLES ?= 1500000
FENCE_ASFLAGS := -march=rv64ima_zicsr_zifencei -mabi=lp64 \
	-mcmodel=medany -mno-relax -nostdlib -nostartfiles

FENCE_CORRECT_ELF := $(FENCE_BUILD_DIR)/fence-correctness-sv39.elf
FENCE_CORRECT_BIN := $(FENCE_BUILD_DIR)/fence-correctness-sv39.bin
FENCE_CORRECT_MEMH := $(FENCE_BUILD_DIR)/fence-correctness-sv39.memh
FENCE_CORRECT_MAP := $(FENCE_BUILD_DIR)/fence-correctness-sv39.map
FENCE_CORRECT_DISASM := $(FENCE_BUILD_DIR)/fence-correctness-sv39.disasm
FENCE_CORRECT_PASS := 46454e43454f4b21
FENCE_CORRECT_DONE = $(shell $(RISCV_NM) -n $(FENCE_CORRECT_ELF) | \
	awk '$$3 == "fence_vm_done" { print $$1 }')

FENCE_CASE ?= 0
FENCE_CASE_IDS := 1 2 3 4 5 6 7 8 9
FENCE_CASE_ELF = $(FENCE_BUILD_DIR)/fence-case-$(FENCE_CASE)-sv39.elf
FENCE_CASE_BIN = $(FENCE_BUILD_DIR)/fence-case-$(FENCE_CASE)-sv39.bin
FENCE_CASE_MEMH = $(FENCE_BUILD_DIR)/fence-case-$(FENCE_CASE)-sv39.memh
FENCE_CASE_MAP = $(FENCE_BUILD_DIR)/fence-case-$(FENCE_CASE)-sv39.map
FENCE_CASE_DISASM = \
	$(FENCE_BUILD_DIR)/fence-case-$(FENCE_CASE)-sv39.disasm
FENCE_CASE_DONE = $(shell $(RISCV_NM) -n $(FENCE_CASE_ELF) 2>/dev/null | \
	awk '$$3 == "fence_vm_done" { print $$1 }')

FENCE_BENCH_ELF := $(FENCE_BUILD_DIR)/fence-bench-sv39.elf
FENCE_BENCH_BIN := $(FENCE_BUILD_DIR)/fence-bench-sv39.bin
FENCE_BENCH_MEMH := $(FENCE_BUILD_DIR)/fence-bench-sv39.memh
FENCE_BENCH_MAP := $(FENCE_BUILD_DIR)/fence-bench-sv39.map
FENCE_BENCH_DISASM := $(FENCE_BUILD_DIR)/fence-bench-sv39.disasm
FENCE_BENCH_DONE = $(shell $(RISCV_NM) -n $(FENCE_BENCH_ELF) | \
	awk '$$3 == "fence_vm_done" { print $$1 }')

ATOMIC_SV39_ELF := $(FENCE_BUILD_DIR)/atomic-sv39.elf
ATOMIC_SV39_BIN := $(FENCE_BUILD_DIR)/atomic-sv39.bin
ATOMIC_SV39_MEMH := $(FENCE_BUILD_DIR)/atomic-sv39.memh
ATOMIC_SV39_MAP := $(FENCE_BUILD_DIR)/atomic-sv39.map
ATOMIC_SV39_DISASM := $(FENCE_BUILD_DIR)/atomic-sv39.disasm
ATOMIC_SV39_DONE = $(shell $(RISCV_NM) -n $(ATOMIC_SV39_ELF) | \
	awk '$$3 == "fence_vm_done" { print $$1 }')

.PHONY: sw-fence-sv39 sw-atomic-sv39 sim-fence-sv39-order \
	sim-fence-sv39-case \
	sim-atomic-sv39 check-fence-sv39 bench-fence-sv39 \
	fence-sv39-suite

$(FENCE_CORRECT_ELF): $(OPENRV64_MAKEFILES) \
		$(FENCE_SV39_BOOT) sw/fence/fence_correctness.S $(FENCE_SV39_LD)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FENCE_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FENCE_CORRECT_MAP) \
		-T $(FENCE_SV39_LD) -o $@ \
		$(FENCE_SV39_BOOT) sw/fence/fence_correctness.S

$(FENCE_BENCH_ELF): $(OPENRV64_MAKEFILES) \
		$(FENCE_SV39_BOOT) sw/fence/fence_bench.S $(FENCE_SV39_LD)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FENCE_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FENCE_BENCH_MAP) \
		-T $(FENCE_SV39_LD) -o $@ \
		$(FENCE_SV39_BOOT) sw/fence/fence_bench.S

$(FENCE_CASE_ELF): $(OPENRV64_MAKEFILES) \
		$(FENCE_SV39_BOOT) sw/fence/fence_correctness.S $(FENCE_SV39_LD)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FENCE_ASFLAGS) -DFENCE_CASE=$(FENCE_CASE) \
		-Wl,--build-id=none,-Map,$(FENCE_CASE_MAP) \
		-T $(FENCE_SV39_LD) -o $@ \
		$(FENCE_SV39_BOOT) sw/fence/fence_correctness.S

$(ATOMIC_SV39_ELF): $(OPENRV64_MAKEFILES) \
		$(FENCE_SV39_BOOT) sw/atomic/atomic.S $(FENCE_SV39_LD)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FENCE_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(ATOMIC_SV39_MAP) \
		-T $(FENCE_SV39_LD) -o $@ \
		$(FENCE_SV39_BOOT) sw/atomic/atomic.S

$(FENCE_CORRECT_BIN): $(FENCE_CORRECT_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FENCE_BENCH_BIN): $(FENCE_BENCH_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FENCE_CASE_BIN): $(FENCE_CASE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ATOMIC_SV39_BIN): $(ATOMIC_SV39_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FENCE_CORRECT_MEMH): $(FENCE_CORRECT_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FENCE_MEMH_BYTES) --word-bytes 32

$(FENCE_BENCH_MEMH): $(FENCE_BENCH_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FENCE_MEMH_BYTES) --word-bytes 32

$(FENCE_CASE_MEMH): $(FENCE_CASE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FENCE_MEMH_BYTES) --word-bytes 32

$(ATOMIC_SV39_MEMH): $(ATOMIC_SV39_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FENCE_MEMH_BYTES) --word-bytes 32

$(FENCE_CORRECT_DISASM): $(FENCE_CORRECT_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FENCE_BENCH_DISASM): $(FENCE_BENCH_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FENCE_CASE_DISASM): $(FENCE_CASE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_SV39_DISASM): $(ATOMIC_SV39_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

sw-fence-sv39: $(FENCE_CORRECT_ELF) $(FENCE_CORRECT_BIN) \
	$(FENCE_CORRECT_MEMH) $(FENCE_CORRECT_DISASM) \
	$(FENCE_BENCH_ELF) $(FENCE_BENCH_BIN) \
	$(FENCE_BENCH_MEMH) $(FENCE_BENCH_DISASM)

sw-atomic-sv39: $(ATOMIC_SV39_ELF) $(ATOMIC_SV39_BIN) \
	$(ATOMIC_SV39_MEMH) $(ATOMIC_SV39_DISASM)

sim-fence-sv39-order: $(FENCE_CORRECT_MEMH)
	test -n "$(FENCE_CORRECT_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=0 \
		CORE_3P_ICX_L2_DDR3=0 \
		CORE_3P_ICX_L2_MEMH=$(FENCE_CORRECT_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(FENCE_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(FENCE_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(FENCE_CORRECT_PASS) +done_pc=$(FENCE_CORRECT_DONE) +require_sv39 +fence_check"

sim-fence-sv39-case: $(FENCE_CASE_MEMH) $(FENCE_CASE_DISASM)
	test -n "$(FENCE_CASE_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=0 \
		CORE_3P_ICX_L2_DDR3=0 \
		CORE_3P_ICX_L2_MEMH=$(FENCE_CASE_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(FENCE_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(FENCE_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(FENCE_CORRECT_PASS) +done_pc=$(FENCE_CASE_DONE) +fence_sv39_active +fence_check +fence_case=$(FENCE_CASE)"

sim-atomic-sv39: $(ATOMIC_SV39_MEMH)
	test -n "$(ATOMIC_SV39_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=0 \
		CORE_3P_ICX_L2_DDR3=0 \
		CORE_3P_ICX_L2_MEMH=$(ATOMIC_SV39_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(FENCE_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(FENCE_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(ATOMIC_SOC_PASS) +done_pc=$(ATOMIC_SV39_DONE) +require_sv39"

bench-fence-sv39: $(FENCE_BENCH_MEMH)
	test -n "$(FENCE_BENCH_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=0 \
		CORE_3P_ICX_L2_DDR3=0 \
		CORE_3P_ICX_L2_MEMH=$(FENCE_BENCH_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(FENCE_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(FENCE_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(FENCE_BENCH_DONE) +require_sv39 +report_a_regs"

check-fence-sv39:
	@status=0; \
	for case_id in $(FENCE_CASE_IDS); do \
		$(MAKE) sim-fence-sv39-case FENCE_CASE=$$case_id || status=1; \
	done; \
	for target in sim-atomic-sv39 sim-atomic-soc \
			sim-exec-lsu-rv64-a sim-atomic-context; do \
		$(MAKE) $$target || status=1; \
	done; \
	exit $$status

fence-sv39-suite:
	@status=0; \
	$(MAKE) check-fence-sv39 || status=1; \
	$(MAKE) bench-fence-sv39 || status=1; \
	exit $$status
