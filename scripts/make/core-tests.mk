# Scalar core, backend, vector, and branch-predictor simulation targets.

sim-decode-early: $(DECODE_EARLY_SIM_BUILD)
	vvp $(DECODE_EARLY_SIM_BUILD)

sim-decode-top: $(DECODE_TOP_SIM_BUILD)
	vvp $(DECODE_TOP_SIM_BUILD)

sim-decode-rv64-fd: $(DECODE_RV64FD_SIM_BUILD)
	vvp $(DECODE_RV64FD_SIM_BUILD)

sim-decode-rv64c: $(DECODE_RV64C_SIM_BUILD)
	vvp $(DECODE_RV64C_SIM_BUILD)

sim-decode-imm: $(DECODE_IMM_SIM_BUILD)
	vvp $(DECODE_IMM_SIM_BUILD)

sim-decode-alu: $(DECODE_ALU_SIM_BUILD)
	vvp $(DECODE_ALU_SIM_BUILD)

sim-decode-lsu: $(DECODE_LSU_SIM_BUILD)
	vvp $(DECODE_LSU_SIM_BUILD)

sim-decode-reg-alu: $(DECODE_REG_ALU_SIM_BUILD)
	vvp $(DECODE_REG_ALU_SIM_BUILD)

sim-decode-reg-lsu: $(DECODE_REG_LSU_SIM_BUILD)
	vvp $(DECODE_REG_LSU_SIM_BUILD)

sim-decode-br: $(DECODE_BR_SIM_BUILD)
	vvp $(DECODE_BR_SIM_BUILD)

sim-isa-bitmanip: $(ISA_BITMANIP_SIM_BUILD)
	vvp $(ISA_BITMANIP_SIM_BUILD)

sim-isa-fp: $(ISA_FP_SIM_BUILD)
	vvp $(ISA_FP_SIM_BUILD)

sim-rv64-fd-fpr: $(RV64FD_FPR_SIM_BUILD)
	vvp $(RV64FD_FPR_SIM_BUILD)

sim-fpu-csrs: $(FPU_CSRS_SIM_BUILD)
	vvp $(FPU_CSRS_SIM_BUILD)

sim-stage: $(STAGE_SIM_BUILD)
	vvp $(STAGE_SIM_BUILD)

sim-regfile: $(REGFILE_SIM_BUILD)
	vvp $(REGFILE_SIM_BUILD)

sim-prf: $(PRF_SIM_BUILD)
	vvp $(PRF_SIM_BUILD)

sim-rename-identity: $(RENAME_IDENTITY_SIM_BUILD)
	vvp $(RENAME_IDENTITY_SIM_BUILD)

sim-rename-tomasulo: $(RENAME_TOMASULO_SIM_BUILD)
	vvp $(RENAME_TOMASULO_SIM_BUILD)

sim-rv64-i-gpr: $(RV64I_GPR_SIM_BUILD)
	vvp $(RV64I_GPR_SIM_BUILD)

sim-rv64-i-gpr-banked: $(RV64I_GPR_BANKED_SIM_BUILD)
	vvp $(RV64I_GPR_BANKED_SIM_BUILD)

sim-rv64-i-gpr-3p: $(RV64I_GPR_3P_SIM_BUILD)
	vvp $(RV64I_GPR_3P_SIM_BUILD)

sim-rv64-i-csrs: $(RV64I_CSRS_SIM_BUILD)
	vvp $(RV64I_CSRS_SIM_BUILD)

sim-rv64-i-pmp: $(RV64I_PMP_SIM_BUILD)
	vvp $(RV64I_PMP_SIM_BUILD)

sim-fetch: $(FETCH_SIM_BUILD) $(FETCH_NOTRACE_SIM_BUILD) \
	$(FETCH_NOPREDECODE_SIM_BUILD)
	vvp $(FETCH_SIM_BUILD)
	vvp $(FETCH_NOTRACE_SIM_BUILD)
	vvp $(FETCH_NOPREDECODE_SIM_BUILD)

sim-fetch-2p: $(FETCH_2P_SIM_BUILD)
	vvp $(FETCH_2P_SIM_BUILD)

sim-fetch-3w: $(FETCH_3W_SIM_BUILD) $(FETCH_3W_CAROUSEL_SIM_BUILD) \
		$(FETCH_3W_SECTOR_SIM_BUILD) \
		$(FETCH_3W_PAIR512_SIM_BUILD) $(FETCH_3W_PAIR1024_SIM_BUILD)
	vvp $(FETCH_3W_SIM_BUILD)
	vvp $(FETCH_3W_CAROUSEL_SIM_BUILD)
	vvp $(FETCH_3W_SECTOR_SIM_BUILD)
	vvp $(FETCH_3W_PAIR512_SIM_BUILD)
	vvp $(FETCH_3W_PAIR1024_SIM_BUILD)

sim-prefix-addsub: $(PREFIX_ADDSUB_SIM_BUILD)
	vvp $(PREFIX_ADDSUB_SIM_BUILD)

sim-dispatch: $(DISPATCH_SIM_BUILD)
	vvp $(DISPATCH_SIM_BUILD)

sim-dispatch-barrier-3p: $(DISPATCH_BARRIER_3P_SIM_BUILD)
	vvp $(DISPATCH_BARRIER_3P_SIM_BUILD)

sim-dispatch-issue-3p: $(DISPATCH_ISSUE_3P_SIM_BUILD)
	vvp $(DISPATCH_ISSUE_3P_SIM_BUILD)

sim-dispatch-window-3p: $(DISPATCH_WINDOW_3P_SIM_BUILD)
	vvp $(DISPATCH_WINDOW_3P_SIM_BUILD)

sim-dispatch-3p: $(DISPATCH_3P_SIM_BUILD)
	vvp $(DISPATCH_3P_SIM_BUILD)

sim-dispatch-3p-banked: $(DISPATCH_3P_BANKED_SIM_BUILD)
	vvp $(DISPATCH_3P_BANKED_SIM_BUILD)

sim-fd-dispatch: $(FD_DISPATCH_SIM_BUILD)
	vvp $(FD_DISPATCH_SIM_BUILD)

sim-fd-uop-harness: $(FD_UOP_HARNESS_SIM_BUILD) \
		$(FD_UOP_HARNESS_COMPACT_MUL_SIM_BUILD)
	vvp $(FD_UOP_HARNESS_SIM_BUILD)
	vvp $(FD_UOP_HARNESS_COMPACT_MUL_SIM_BUILD)

sim-fd-uop-harness-compact-mul: $(FD_UOP_HARNESS_COMPACT_MUL_SIM_BUILD)
	vvp $(FD_UOP_HARNESS_COMPACT_MUL_SIM_BUILD)

sim-reg-map-3p: $(REG_MAP_3P_SIM_BUILD)
	vvp $(REG_MAP_3P_SIM_BUILD)

sim-exec-alu-rv64-i: $(EXEC_ALU_RV64I_SIM_BUILD)
	vvp $(EXEC_ALU_RV64I_SIM_BUILD)

sim-exec-alu-rv64-m: $(EXEC_ALU_RV64M_SIM_BUILD)
	vvp $(EXEC_ALU_RV64M_SIM_BUILD)

sim-exec-alu-rv64-m-fpga: $(EXEC_ALU_RV64M_FPGA_SIM_BUILD)
	vvp $(EXEC_ALU_RV64M_FPGA_SIM_BUILD)

sim-exec-ext-zbb: $(EXEC_EXT_ZBB_SIM_BUILD) $(EXEC_ZBB_ROTATE_SIM_BUILD)
	vvp $(EXEC_EXT_ZBB_SIM_BUILD)
	vvp $(EXEC_ZBB_ROTATE_SIM_BUILD)

sim-exec-top-3p: $(EXEC_TOP_3P_SIM_BUILD)
	vvp $(EXEC_TOP_3P_SIM_BUILD)

sim-exec-top-3p-no-zicclsm: $(EXEC_TOP_3P_NO_ZICCLSM_SIM_BUILD)
	vvp $(EXEC_TOP_3P_NO_ZICCLSM_SIM_BUILD)

sim-lsu-misaligned: $(LSU_MISALIGNED_SIM_BUILD)
	vvp $(LSU_MISALIGNED_SIM_BUILD)

sim-lsq: $(LSQ_SIM_BUILD)
	vvp $(LSQ_SIM_BUILD)

sim-lsu-atomics: $(LSU_ATOMICS_SIM_BUILD)
	vvp $(LSU_ATOMICS_SIM_BUILD)

sim-exec-pipe-mem-timeout: $(EXEC_PIPE_MEM_TIMEOUT_SIM_BUILD)
	@mkdir -p sim
	@if vvp $(EXEC_PIPE_MEM_TIMEOUT_SIM_BUILD) \
		> sim/exec_pipe_mem_timeout.log 2>&1; then \
		cat sim/exec_pipe_mem_timeout.log; \
		echo "FAIL: LSU timeout assertion did not fire"; \
		exit 1; \
	elif grep -q "LSU operation timeout cycles=4" \
		sim/exec_pipe_mem_timeout.log; then \
		cat sim/exec_pipe_mem_timeout.log; \
		echo "PASS: LSU operation timeout assertion"; \
	else \
		cat sim/exec_pipe_mem_timeout.log; \
		exit 1; \
	fi

sim-exec-lsu-rv64-i: $(EXEC_LSU_RV64I_SIM_BUILD)
	vvp $(EXEC_LSU_RV64I_SIM_BUILD)

sim-exec-lsu-rv64-a: $(EXEC_LSU_RV64A_SIM_BUILD)
	vvp $(EXEC_LSU_RV64A_SIM_BUILD)

sim-atomic-context: $(ATOMIC_CONTEXT_SIM_BUILD)
	vvp $(ATOMIC_CONTEXT_SIM_BUILD)

sim-recursive-lock-context: $(RECURSIVE_LOCK_CONTEXT_SIM_BUILD)
	vvp $(RECURSIVE_LOCK_CONTEXT_SIM_BUILD)

sim-wfi-context: $(WFI_CONTEXT_SIM_BUILD)
	vvp $(WFI_CONTEXT_SIM_BUILD)

sim-exec-br: $(EXEC_BR_SIM_BUILD)
	vvp $(EXEC_BR_SIM_BUILD)

sim-exec-bp: $(EXEC_BP_SIM_BUILD) $(EXEC_BP_GSHARE_BTB_SIM_BUILD) \
	$(EXEC_BP_TAGGED_SPEC_SIM_BUILD) $(EXEC_BP_MODES78_SIM_BUILD) \
	$(EXEC_BP_TAGE_SIM_BUILD)
	vvp $(EXEC_BP_SIM_BUILD)
	vvp $(EXEC_BP_GSHARE_BTB_SIM_BUILD)
	vvp $(EXEC_BP_TAGGED_SPEC_SIM_BUILD)
	vvp $(EXEC_BP_MODES78_SIM_BUILD)
	vvp $(EXEC_BP_TAGE_SIM_BUILD)

sim-exec-bp-basic: $(EXEC_BP_SIM_BUILD)
	vvp $(EXEC_BP_SIM_BUILD)

sim-exec-bp-tage: $(EXEC_BP_TAGE_SIM_BUILD)
	vvp $(EXEC_BP_TAGE_SIM_BUILD)

sim-exec-fpu-rv64-fd: $(EXEC_FPU_RV64FD_SIM_BUILD) \
		$(EXEC_FPU_RV64FD_COMPACT_MUL_SIM_BUILD)
	vvp $(EXEC_FPU_RV64FD_SIM_BUILD)
	vvp $(EXEC_FPU_RV64FD_COMPACT_MUL_SIM_BUILD)

sim-exec-fpu-rv64-fd-compact-mul: $(EXEC_FPU_RV64FD_COMPACT_MUL_SIM_BUILD)
	vvp $(EXEC_FPU_RV64FD_COMPACT_MUL_SIM_BUILD)

sim-vec: sim-rv64-i-vec sim-exec-vec sim-exec-vec-lsu sim-vec-cache \
	sim-vec-cache-axi sim-vec-cache-wb sim-vec-cache-wb-512 \
	sim-vec-test-top \
	sim-vec-matmul sim-vec-matmul-bf16

sim-rv64-i-vec: $(RV64I_VEC_SIM_BUILD)
	vvp $(RV64I_VEC_SIM_BUILD)

sim-exec-vec: $(EXEC_VEC_SIM_BUILD)
	vvp $(EXEC_VEC_SIM_BUILD)

sim-exec-vec-lsu: $(EXEC_VEC_LSU_SIM_BUILD)
	vvp $(EXEC_VEC_LSU_SIM_BUILD)

sim-vec-cache: $(VEC_CACHE_SIM_BUILD)
	vvp $(VEC_CACHE_SIM_BUILD)

sim-vec-cache-axi: $(VEC_CACHE_AXI_SIM_BUILD)
	vvp $(VEC_CACHE_AXI_SIM_BUILD)

sim-vec-cache-wb: $(VEC_CACHE_WB_SIM_BUILD)
	vvp $(VEC_CACHE_WB_SIM_BUILD)

sim-vec-cache-wb-512: $(VEC_CACHE_WB_512_SIM_BUILD)
	vvp $(VEC_CACHE_WB_512_SIM_BUILD)

sim-vec-test-top: $(VEC_TEST_TOP_SIM_BUILD)
	vvp $(VEC_TEST_TOP_SIM_BUILD)

sim-vec-matmul: $(VEC_MATMUL_SIM_BUILD) $(VEC_MATMUL_MEMH)
	vvp $(VEC_MATMUL_SIM_BUILD) +memh=$(VEC_MATMUL_MEMH)

sim-vec-matmul-bf16: $(VEC_MATMUL_BF16_SIM_BUILD) \
		$(VEC_MATMUL_BF16_MEMH)
	vvp $(VEC_MATMUL_BF16_SIM_BUILD) +memh=$(VEC_MATMUL_BF16_MEMH)

sim-bp-context: sim-bp-context-always-branch sim-bp-context-no-predecode \
	sim-bp-context-always-decline sim-bp-context-repeat-last \
	sim-bp-context-btfnt sim-bp-context-bimodal \
	sim-bp-context-gshare-btb sim-bp-context-gshare-btb-512 \
	sim-bp-context-tournament-btb sim-bp-context-tage-btb

sim-bp-context-always-branch: $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)

sim-bp-context-no-predecode: $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)
	vvp $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)

sim-bp-context-always-decline: $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)

sim-bp-context-repeat-last: $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)
	vvp $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)

sim-bp-context-btfnt: $(BP_CONTEXT_BTFNT_SIM_BUILD)
	vvp $(BP_CONTEXT_BTFNT_SIM_BUILD)

sim-bp-context-bimodal: $(BP_CONTEXT_BIMODAL_SIM_BUILD)
	vvp $(BP_CONTEXT_BIMODAL_SIM_BUILD)

sim-bp-context-gshare-btb: $(BP_CONTEXT_GSHARE_BTB_SIM_BUILD)
	vvp $(BP_CONTEXT_GSHARE_BTB_SIM_BUILD)

sim-bp-context-gshare-btb-512: $(BP_CONTEXT_GSHARE_BTB_512_SIM_BUILD)
	vvp $(BP_CONTEXT_GSHARE_BTB_512_SIM_BUILD)

sim-bp-context-tournament-btb: $(BP_CONTEXT_TOURNAMENT_BTB_SIM_BUILD)
	vvp $(BP_CONTEXT_TOURNAMENT_BTB_SIM_BUILD)

sim-bp-context-tage-btb: $(BP_CONTEXT_TAGE_BTB_SIM_BUILD)
	vvp $(BP_CONTEXT_TAGE_BTB_SIM_BUILD)

sim-bp-context-tage-btb-nopredecode: \
		$(BP_CONTEXT_TAGE_BTB_NOPREDECODE_SIM_BUILD)
	vvp $(BP_CONTEXT_TAGE_BTB_NOPREDECODE_SIM_BUILD)

sim-bp-context-fpga-queue: $(BP_CONTEXT_FPGA_QUEUE_SIM_BUILD)
	vvp $(BP_CONTEXT_FPGA_QUEUE_SIM_BUILD)

sim-except: $(EXCEPT_SIM_BUILD)
	vvp $(EXCEPT_SIM_BUILD)

sim-exec-system-csr: $(EXEC_SYSTEM_CSR_SIM_BUILD)
	vvp $(EXEC_SYSTEM_CSR_SIM_BUILD)

sim-trap-context: $(TRAP_CONTEXT_SIM_BUILD)
	vvp $(TRAP_CONTEXT_SIM_BUILD)

sim-priv-context: $(PRIV_CONTEXT_SIM_BUILD)
	vvp $(PRIV_CONTEXT_SIM_BUILD)

sim-irq-context: $(IRQ_CONTEXT_SIM_BUILD)
	vvp $(IRQ_CONTEXT_SIM_BUILD)

sim-zicclsm-context: $(ZICCLSM_CONTEXT_SIM_BUILD)
	vvp $(ZICCLSM_CONTEXT_SIM_BUILD)

sim-load-use-context: $(LOAD_USE_CONTEXT_SIM_BUILD)
	vvp $(LOAD_USE_CONTEXT_SIM_BUILD)

sim-reg-owner: $(REG_OWNER_SIM_BUILD)
	vvp $(REG_OWNER_SIM_BUILD)

sim-retire-queue-3p: $(RETIRE_QUEUE_3P_SIM_BUILD)
	vvp $(RETIRE_QUEUE_3P_SIM_BUILD)

sim-retire-3p: $(RETIRE_3P_SIM_BUILD)
	vvp $(RETIRE_3P_SIM_BUILD)

sim-retire-3p-banked: $(RETIRE_3P_BANKED_SIM_BUILD)
	vvp $(RETIRE_3P_BANKED_SIM_BUILD)

sim-backend-3p: $(BACKEND_3P_SIM_BUILD)
	vvp $(BACKEND_3P_SIM_BUILD)

sim-backend-3p-banked: $(BACKEND_3P_BANKED_SIM_BUILD)
	vvp $(BACKEND_3P_BANKED_SIM_BUILD)

sim-backend-3p-banked-tomasulo: $(BACKEND_3P_BANKED_TOMASULO_SIM_BUILD)
	vvp $(BACKEND_3P_BANKED_TOMASULO_SIM_BUILD)

sim-backend-3p-banked-window: $(BACKEND_3P_BANKED_WINDOW_SIM_BUILD)
	vvp $(BACKEND_3P_BANKED_WINDOW_SIM_BUILD)

sim-top-3p: $(TOP_3P_SIM_BUILD)
	vvp $(TOP_3P_SIM_BUILD)

sim-top-3p-banked: $(TOP_3P_BANKED_SIM_BUILD)
	vvp $(TOP_3P_BANKED_SIM_BUILD)

sim-top-4pf: $(TOP_4PF_SIM_BUILD) $(FP_DAXPY_MEMH)
	vvp $(TOP_4PF_SIM_BUILD)

sim-top-4pf-daxpy-compute: $(TOP_4PF_SIM_BUILD) \
		$(FP_DAXPY_COMPUTE_MEMH)
	vvp $(TOP_4PF_SIM_BUILD) +daxpy_compute \
		+memh=$(FP_DAXPY_COMPUTE_MEMH)

sim-top-4pf-daxpy-store: $(TOP_4PF_SIM_BUILD) $(FP_DAXPY_STORE_MEMH)
	vvp $(TOP_4PF_SIM_BUILD) +daxpy_store \
		+memh=$(FP_DAXPY_STORE_MEMH)

sim-top-4pf-fmadd32: $(TOP_4PF_SIM_BUILD) $(FP_FMADD32_MEMH)
	vvp $(TOP_4PF_SIM_BUILD) +fmadd32 +memh=$(FP_FMADD32_MEMH)

sim-top-4pf-faults: $(TOP_4PF_SIM_BUILD) $(FP_FAULTS_MEMH)
	vvp $(TOP_4PF_SIM_BUILD) +faults +memh=$(FP_FAULTS_MEMH)

sim-top-axi-3p: $(TOP_AXI_3P_SIM_BUILD)
	vvp $(TOP_AXI_3P_SIM_BUILD)
