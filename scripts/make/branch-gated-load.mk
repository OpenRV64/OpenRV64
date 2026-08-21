# Directed branch-gated-load performance workload.

BRANCH_GATED_LOAD_VM_ELF := \
	sw/branch-gated-load/branch-gated-load-vm.elf
BRANCH_GATED_LOAD_VM_BIN := \
	sw/branch-gated-load/branch-gated-load-vm.bin
BRANCH_GATED_LOAD_VM_MAP := \
	sw/branch-gated-load/branch-gated-load-vm.map
BRANCH_GATED_LOAD_VM_DISASM := \
	sw/branch-gated-load/branch-gated-load-vm.disasm
BRANCH_GATED_LOAD_VM_MEMH := sim/branch-gated-load-vm.memh
BRANCH_GATED_LOAD_VM_MEASURE_END = $(shell $(RISCV_NM) -n \
	$(BRANCH_GATED_LOAD_VM_ELF) | awk \
	'$$3 == "branch_gated_load_measure_end" { print $$1 }')
BRANCH_GATED_LOAD_VM_DONE = $(shell $(RISCV_NM) -n \
	$(BRANCH_GATED_LOAD_VM_ELF) | awk \
	'$$3 == "openrv64_runtime_done" { print $$1 }')
BRANCH_GATED_LOAD_PASS := 4252474c445f4f4b
BRANCH_GATED_LOAD_VM_MEMH_BYTES := 0x44000
BRANCH_GATED_LOAD_VM_MEMH_WORDS := 8704
BRANCH_GATED_LOAD_MAX_CYCLES ?= 5000000
BRANCH_GATED_LOAD_REQUIRE_ARGS ?= +require_ddr3_overlap

.PHONY: sw-branch-gated-load-vm bench-branch-gated-load-ddr3-vm \
	sim-branch-gated-load-ddr3-vm

sw-branch-gated-load-vm: $(BRANCH_GATED_LOAD_VM_ELF) \
		$(BRANCH_GATED_LOAD_VM_BIN) $(BRANCH_GATED_LOAD_VM_MEMH) \
		$(BRANCH_GATED_LOAD_VM_DISASM)

$(BRANCH_GATED_LOAD_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/branch-gated-load/branch_gated_load.S \
		sw/runtime/sv39.S sw/runtime/c_start.inc \
		sw/runtime/openrv64-sv39.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(PREFETCH_ASFLAGS) \
		-DOPENRV64_RUNTIME_NO_BSS_CLEAR \
		-Wl,--build-id=none,-Map,$(BRANCH_GATED_LOAD_VM_MAP) \
		-T sw/runtime/openrv64-sv39.ld -o $@ \
		sw/runtime/sv39.S \
		sw/branch-gated-load/branch_gated_load.S

$(BRANCH_GATED_LOAD_VM_BIN): $(BRANCH_GATED_LOAD_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(BRANCH_GATED_LOAD_VM_MEMH): $(BRANCH_GATED_LOAD_VM_BIN)
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(BRANCH_GATED_LOAD_VM_MEMH_BYTES) --word-bytes 32

$(BRANCH_GATED_LOAD_VM_DISASM): $(BRANCH_GATED_LOAD_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

bench-branch-gated-load-ddr3-vm: $(BRANCH_GATED_LOAD_VM_MEMH)
	test -n "$(BRANCH_GATED_LOAD_VM_MEASURE_END)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BRANCH_GATED_LOAD_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BRANCH_GATED_LOAD_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(BRANCH_GATED_LOAD_VM_MEASURE_END) +require_sv39 $(BRANCH_GATED_LOAD_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BRANCH_GATED_LOAD_MAX_CYCLES)

sim-branch-gated-load-ddr3-vm: $(BRANCH_GATED_LOAD_VM_MEMH)
	test -n "$(BRANCH_GATED_LOAD_VM_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(BRANCH_GATED_LOAD_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(BRANCH_GATED_LOAD_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(BRANCH_GATED_LOAD_PASS) +done_pc=$(BRANCH_GATED_LOAD_VM_DONE) +require_sv39 $(BRANCH_GATED_LOAD_REQUIRE_ARGS)" \
		CORE_3P_ICX_L2_MAX_CYCLES=$(BRANCH_GATED_LOAD_MAX_CYCLES)
