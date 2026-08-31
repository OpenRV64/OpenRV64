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

compliance-quick: compliance-smoke-local

compliance-full: compliance-smoke-local compliance-trace-contract

compliance-act4-trace-3p-ab: $(COMPLIANCE_3P_M_VLT_BUILD) \
		$(COMPLIANCE_3P_BANKED_M_VLT_BUILD)
	@test -f "$(COMPLIANCE_ACT4_TRACE_ELF)" || \
		{ echo "missing ACT4 trace ELF $(COMPLIANCE_ACT4_TRACE_ELF)"; exit 1; }
	-$(PYTHON) -u tools/compliance.py run \
		"$(COMPLIANCE_ACT4_TRACE_ELF)" \
		--backend 3p --engine verilator --trace \
		--results-dir "$(COMPLIANCE_ACT4_TRACE_RESULTS_DIR)"
	-$(PYTHON) -u tools/compliance.py run \
		"$(COMPLIANCE_ACT4_TRACE_ELF)" \
		--backend 3p-banked --engine verilator --trace \
		--results-dir "$(COMPLIANCE_ACT4_TRACE_RESULTS_DIR)"

compliance-act4-3p: $(COMPLIANCE_3P_M_VLT_BUILD)
	@test -n "$(strip $(COMPLIANCE_ACT4_RV64IMA_ELFS))" || \
		{ echo "missing preserved ACT4 ELFs under $(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)"; exit 1; }
	$(PYTHON) -u tools/compliance.py suite \
		"$(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)" \
		--backend 3p --engine verilator \
		--results-dir "$(COMPLIANCE_3P_RESULTS_DIR)" \
		--junit "$(COMPLIANCE_3P_JUNIT)"

compliance-act4-3p-banked: $(COMPLIANCE_3P_BANKED_M_VLT_BUILD)
	@test -n "$(strip $(COMPLIANCE_ACT4_RV64IMA_ELFS))" || \
		{ echo "missing preserved ACT4 ELFs under $(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)"; exit 1; }
	$(PYTHON) -u tools/compliance.py suite \
		"$(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)" \
		--backend 3p-banked --engine verilator \
		--results-dir "$(COMPLIANCE_3P_BANKED_RESULTS_DIR)" \
		--junit "$(COMPLIANCE_3P_BANKED_JUNIT)"

compliance-act4-platform-3p-ddr3: \
		$(COMPLIANCE_PLATFORM_3P_DDR3_M_VLT_BUILD)
	@test -n "$(strip $(COMPLIANCE_ACT4_RV64IMA_ELFS))" || \
		{ echo "missing preserved ACT4 ELFs under $(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)"; exit 1; }
	$(PYTHON) -u tools/compliance.py suite \
		"$(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)" \
		--backend platform-3p-ddr3 --engine verilator \
		--results-dir "$(COMPLIANCE_PLATFORM_3P_DDR3_RESULTS_DIR)" \
		--junit "$(COMPLIANCE_PLATFORM_3P_DDR3_JUNIT)"

compliance-act4-platform-3p-banked-ddr3: \
		$(COMPLIANCE_PLATFORM_3P_BANKED_DDR3_M_VLT_BUILD)
	@test -n "$(strip $(COMPLIANCE_ACT4_RV64IMA_ELFS))" || \
		{ echo "missing preserved ACT4 ELFs under $(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)"; exit 1; }
	$(PYTHON) -u tools/compliance.py suite \
		"$(COMPLIANCE_ACT4_RV64IMA_ELF_ROOT)" \
		--backend platform-3p-banked-ddr3 --engine verilator \
		--results-dir "$(COMPLIANCE_PLATFORM_3P_BANKED_DDR3_RESULTS_DIR)" \
		--junit "$(COMPLIANCE_PLATFORM_3P_BANKED_DDR3_JUNIT)"
