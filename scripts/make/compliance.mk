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
