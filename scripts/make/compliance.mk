# Architectural compliance workflows.

compliance-doctor:
	$(PYTHON) tools/compliance.py doctor

compliance-smoke-local: compliance-smoke-local-1p compliance-smoke-local-3p \
	compliance-smoke-local-platform compliance-smoke-local-platform-3p

compliance-smoke-local-1p: $(COMPLIANCE_1P_M_BUILD) \
		$(COMPLIANCE_SMOKE_MEMH64)
	vvp $(COMPLIANCE_1P_M_BUILD) \
		+memh=$(COMPLIANCE_SMOKE_MEMH64) \
		+tohost=$(COMPLIANCE_SMOKE_TOHOST) +test=local-smoke-1p

compliance-smoke-local-3p: $(COMPLIANCE_3P_M_BUILD) \
		$(COMPLIANCE_SMOKE_MEMH256)
	vvp $(COMPLIANCE_3P_M_BUILD) \
		+memh=$(COMPLIANCE_SMOKE_MEMH256) \
		+tohost=$(COMPLIANCE_SMOKE_TOHOST) +test=local-smoke-3p

compliance-smoke-local-platform: $(COMPLIANCE_PLATFORM_M_BUILD) \
		$(COMPLIANCE_SMOKE_MEMH64)
	vvp $(COMPLIANCE_PLATFORM_M_BUILD) \
		+memh=$(COMPLIANCE_SMOKE_MEMH64) \
		+tohost=$(COMPLIANCE_SMOKE_TOHOST) +test=local-smoke-platform

compliance-smoke-local-platform-3p: $(COMPLIANCE_PLATFORM_3P_M_VLT_BUILD) \
		$(COMPLIANCE_SMOKE_MEMH64)
	$(COMPLIANCE_PLATFORM_3P_M_VLT_BUILD) \
		+memh=$(abspath $(COMPLIANCE_SMOKE_MEMH64)) \
		+tohost=$(COMPLIANCE_SMOKE_TOHOST) \
		+test=local-smoke-platform-3p

compliance-act4-generate:
	@test -n "$(ACT4_ROOT)" || \
		{ echo "ACT4_ROOT must name an ACT4 checkout" >&2; exit 2; }
	@test -n "$(SAIL_RISCV)" || \
		{ echo "SAIL_RISCV must name sail_riscv_sim" >&2; exit 2; }
	$(PYTHON) tools/compliance.py act4 --act4-root "$(ACT4_ROOT)" \
		--sail "$(SAIL_RISCV)" --workdir "$(COMPLIANCE_ACT4_WORK)" \
		--extensions "$(COMPLIANCE_EXTENSIONS)"

compliance-act4-priv-generate:
	@test -n "$(ACT4_ROOT)" || \
		{ echo "ACT4_ROOT must name an ACT4 checkout" >&2; exit 2; }
	@test -n "$(SAIL_RISCV)" || \
		{ echo "SAIL_RISCV must name sail_riscv_sim" >&2; exit 2; }
	$(PYTHON) tools/compliance.py act4 --act4-root "$(ACT4_ROOT)" \
		--sail "$(SAIL_RISCV)" --workdir "$(COMPLIANCE_ACT4_WORK)" \
		--extensions "$(COMPLIANCE_PRIV_EXTENSIONS)"

# ACT4's common prologue touches CLINT state even for unprivileged tests, so
# the platform backend is the canonical architectural-certification target.
compliance-isa: compliance-act4-generate
	$(PYTHON) tools/compliance.py suite "$(COMPLIANCE_ACT4_ELFS)/rv64i" \
		--extensions "$(COMPLIANCE_EXTENSIONS)" \
		--backend platform --engine "$(COMPLIANCE_ENGINE)" \
		--xfail "$(COMPLIANCE_XFAIL)" \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/results-platform"

# The 3p target validates the native AXI/CCX path with inert setup MMIO. Use
# compliance-priv for tests that require functional CLINT/PLIC behavior.
compliance-isa-3p: compliance-act4-generate
	$(PYTHON) tools/compliance.py suite "$(COMPLIANCE_ACT4_ELFS)/rv64i" \
		--extensions "$(COMPLIANCE_EXTENSIONS)" \
		--backend 3p --engine "$(COMPLIANCE_ENGINE)" \
		--xfail "$(COMPLIANCE_XFAIL)" \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/results-3p"

# Exact integrated hierarchy: 3p core, L1I/L1D, native CCX, shared L2, then
# the platform decoder and peripherals.  Verilator is mandatory for this path.
compliance-isa-platform-3p: compliance-act4-generate
	$(PYTHON) tools/compliance.py suite "$(COMPLIANCE_ACT4_ELFS)/rv64i" \
		--extensions "$(COMPLIANCE_EXTENSIONS)" \
		--backend platform-3p --engine verilator \
		--xfail "$(COMPLIANCE_XFAIL)" \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/results-platform-3p"

compliance-priv: compliance-act4-priv-generate
	$(PYTHON) tools/compliance.py suite "$(COMPLIANCE_ACT4_PRIV_ELFS)" \
		--extensions "$(COMPLIANCE_PRIV_EXTENSIONS)" \
		--backend platform --engine "$(COMPLIANCE_ENGINE)" \
		--xfail "$(COMPLIANCE_XFAIL)" \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/results-priv"

compliance-diff: $(COMPLIANCE_SMOKE_ELF)
	@test -n "$(SAIL_RISCV)" || \
		{ echo "SAIL_RISCV must name sail_riscv_sim" >&2; exit 2; }
	$(PYTHON) tools/compliance.py diff $(COMPLIANCE_SMOKE_ELF) \
		--backend 1p --engine "$(COMPLIANCE_ENGINE)" \
		--sail "$(SAIL_RISCV)" \
		--sail-config verification/compliance/act4/openrv64-rv64ima/sail.json
	$(PYTHON) tools/compliance.py diff $(COMPLIANCE_SMOKE_ELF) \
		--backend 3p --engine "$(COMPLIANCE_ENGINE)" \
		--sail "$(SAIL_RISCV)" \
		--sail-config verification/compliance/act4/openrv64-rv64ima/sail.json

compliance-trace-contract: $(COMPLIANCE_SMOKE_ELF)
	$(PYTHON) tools/compliance.py run $(COMPLIANCE_SMOKE_ELF) \
		--backend 1p --engine "$(COMPLIANCE_ENGINE)" --trace \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/trace-contract"
	$(PYTHON) tools/compliance.py run $(COMPLIANCE_SMOKE_ELF) \
		--backend 3p --engine "$(COMPLIANCE_ENGINE)" --trace \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/trace-contract"
	$(PYTHON) tools/compliance.py run $(COMPLIANCE_SMOKE_ELF) \
		--backend platform --engine "$(COMPLIANCE_ENGINE)" --trace \
		--results-dir "$(COMPLIANCE_BUILD_DIR)/trace-contract"
	$(PYTHON) tools/check_arch_trace.py \
		"$(COMPLIANCE_BUILD_DIR)/trace-contract"

compliance-quick: compliance-smoke-local compliance-diff \
	compliance-trace-contract

compliance-full: compliance-smoke-local compliance-isa compliance-isa-3p \
	compliance-isa-platform-3p \
	compliance-priv compliance-diff compliance-trace-contract
