# Scalar core frontend, decode, dispatch, execution, and vector builds.

$(PTW_CONTEXT_SIM_BUILD): $(PTW_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PTW_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(PTW_CONTEXT_SIM_SRCS)

$(DECODE_EARLY_SIM_BUILD): $(DECODE_EARLY_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_EARLY_SIM_BUILD) $(DECODE_EARLY_SIM_SRCS)

$(DECODE_TOP_SIM_BUILD): $(DECODE_TOP_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_TOP_SIM_BUILD) $(DECODE_TOP_SIM_SRCS)

$(DECODE_RV64C_SIM_BUILD): $(DECODE_RV64C_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_RV64C_SIM_BUILD) $(DECODE_RV64C_SIM_SRCS)

$(DECODE_IMM_SIM_BUILD): $(DECODE_IMM_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_IMM_SIM_BUILD) $(DECODE_IMM_SIM_SRCS)

$(DECODE_ALU_SIM_BUILD): $(DECODE_ALU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_ALU_SIM_BUILD) $(DECODE_ALU_SIM_SRCS)

$(DECODE_LSU_SIM_BUILD): $(DECODE_LSU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_LSU_SIM_BUILD) $(DECODE_LSU_SIM_SRCS)

$(DECODE_REG_ALU_SIM_BUILD): $(DECODE_REG_ALU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_REG_ALU_SIM_BUILD) $(DECODE_REG_ALU_SIM_SRCS)

$(DECODE_REG_LSU_SIM_BUILD): $(DECODE_REG_LSU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_REG_LSU_SIM_BUILD) $(DECODE_REG_LSU_SIM_SRCS)

$(DECODE_BR_SIM_BUILD): $(DECODE_BR_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_BR_SIM_BUILD) $(DECODE_BR_SIM_SRCS)

$(ISA_BITMANIP_SIM_BUILD): $(ISA_BITMANIP_SIM_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ISA_BITMANIP_SIM_BUILD) $(ISA_BITMANIP_SIM_SRCS)

$(ISA_FP_SIM_BUILD): $(ISA_FP_SIM_SRCS) $(FP_ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ISA_FP_SIM_BUILD) $(ISA_FP_SIM_SRCS)

$(RV64FD_FPR_SIM_BUILD): $(RV64FD_FPR_SIM_SRCS) $(FPR_SRCS) \
		$(FP_ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_rv64fd_fpr \
		-o $(RV64FD_FPR_SIM_BUILD) $(RV64FD_FPR_SIM_SRCS)

$(STAGE_SIM_BUILD): $(STAGE_SIM_SRCS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(STAGE_SIM_BUILD) $(STAGE_SIM_SRCS)

$(PRF_SIM_BUILD): rtl/core/regs/prf.v tb/tb_prf.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_prf -o $(PRF_SIM_BUILD) \
		rtl/core/regs/prf.v tb/tb_prf.sv

$(RENAME_IDENTITY_SIM_BUILD): rtl/core/rename/identity.v \
		tb/tb_rename_identity.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_rename_identity \
		-o $(RENAME_IDENTITY_SIM_BUILD) \
		rtl/core/rename/identity.v tb/tb_rename_identity.sv

$(RV64I_GPR_SIM_BUILD): $(RV64I_GPR_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_SIM_BUILD) $(RV64I_GPR_SIM_SRCS)

$(RV64I_GPR_3P_SIM_BUILD): rtl/core/regs/prf.v \
		rtl/core/regs/rv64-i-gpr_3p.v tb/tb_rv64-i-gpr_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_3P_SIM_BUILD) \
		rtl/core/regs/rv64-i-gpr_3p.v tb/tb_rv64-i-gpr_3p.sv

$(RV64I_CSRS_SIM_BUILD): $(RV64I_CSRS_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS) $(EXCEPT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_CSRS_SIM_BUILD) \
		rtl/core/regs/rv64-i-pmp.v $(CMU_SRCS) \
		$(RV64I_CSRS_SIM_SRCS)

$(RV64I_PMP_SIM_BUILD): $(RV64I_PMP_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_PMP_SIM_BUILD) $(RV64I_PMP_SIM_SRCS)

$(FETCH_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_NOTRACE_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_fetch.ENABLE_TRACE=0 \
		-o $(FETCH_NOTRACE_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_NOPREDECODE_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_fetch.ENABLE_TRACE=0 \
		-Ptb_fetch.ENABLE_PREDECODE_TARGETS=0 \
		-o $(FETCH_NOPREDECODE_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_2P_SIM_BUILD): rtl/core/fetch/fetch.v tb/tb_fetch_2p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_2P_SIM_BUILD) tb/tb_fetch_2p.sv

$(FETCH_3W_SIM_BUILD): rtl/core/fetch/fetch_3w.v $(FETCH_3W_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_SIM_SRCS)

$(FETCH_3W_CAROUSEL_SIM_BUILD): rtl/core/fetch/fetch_3w.v \
		$(FETCH_3W_CAROUSEL_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_CAROUSEL_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_CAROUSEL_SIM_SRCS)

$(FETCH_3W_SECTOR_SIM_BUILD): rtl/core/fetch/fetch_3w.v \
		$(FETCH_3W_SECTOR_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_SECTOR_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_SECTOR_SIM_SRCS)

$(FETCH_3W_PAIR512_SIM_BUILD): rtl/core/fetch/fetch_3w.v \
		$(FETCH_3W_PAIR512_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_PAIR512_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_PAIR512_SIM_SRCS)

$(FETCH_3W_PAIR1024_SIM_BUILD): rtl/core/fetch/fetch_3w.v \
		$(FETCH_3W_PAIR1024_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_PAIR1024_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_PAIR1024_SIM_SRCS)

$(PREFIX_ADDSUB_SIM_BUILD): $(PREFIX_ADDSUB_SIM_SRCS) rtl/core/arith/prefix-addsub.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PREFIX_ADDSUB_SIM_BUILD) $(PREFIX_ADDSUB_SIM_SRCS)

$(DISPATCH_SIM_BUILD): $(DISPATCH_SIM_SRCS) $(DISPATCH_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_SIM_BUILD) $(DISPATCH_SRCS) $(DISPATCH_SIM_SRCS)

$(DISPATCH_BARRIER_3P_SIM_BUILD): rtl/core/dispatch/dispatch_barrier_3p.v tb/tb_dispatch_barrier_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_BARRIER_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_barrier_3p.v tb/tb_dispatch_barrier_3p.sv

$(DISPATCH_ISSUE_3P_SIM_BUILD): rtl/core/dispatch/dispatch_issue_3p.v tb/tb_dispatch_issue_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_ISSUE_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_issue_3p.v tb/tb_dispatch_issue_3p.sv

$(DISPATCH_WINDOW_3P_SIM_BUILD): rtl/core/dispatch/dispatch_window_3p.v tb/tb_dispatch_window_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_WINDOW_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_window_3p.v tb/tb_dispatch_window_3p.sv

$(DISPATCH_3P_SIM_BUILD): rtl/core/dispatch/dispatch_3p.v \
	rtl/core/dispatch/reg_map_3p.v rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v tb/tb_dispatch_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_3P_SIM_BUILD) \
		rtl/core/dispatch/reg_map_3p.v \
		rtl/core/dispatch/dispatch_barrier_3p.v \
		rtl/core/dispatch/dispatch_issue_3p.v \
		rtl/core/dispatch/dispatch_control_3p.v \
		rtl/core/dispatch/dispatch_3p.v tb/tb_dispatch_3p.sv

$(REG_MAP_3P_SIM_BUILD): rtl/core/dispatch/reg_map_3p.v tb/tb_reg_map_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(REG_MAP_3P_SIM_BUILD) \
		rtl/core/dispatch/reg_map_3p.v tb/tb_reg_map_3p.sv

$(EXEC_ALU_RV64I_SIM_BUILD): $(EXEC_ALU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64I_SIM_BUILD) $(EXEC_ALU_RV64I_SIM_SRCS)

$(EXEC_ALU_RV64M_SIM_BUILD): $(EXEC_ALU_RV64M_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64M_SIM_BUILD) $(EXEC_ALU_RV64M_SIM_SRCS)

$(EXEC_TOP_3P_SIM_BUILD): tb/tb_exec_top_3p.sv $(EXEC_SRCS) $(EXCEPT_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_TOP_3P_SIM_BUILD) \
		$(EXEC_SRCS) $(EXCEPT_SRCS) $(ARITH_DEPS) $(STAGE_SRCS) tb/tb_exec_top_3p.sv

$(EXEC_TOP_3P_NO_ZICCLSM_SIM_BUILD): tb/tb_exec_top_3p.sv $(EXEC_SRCS) $(EXCEPT_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_exec_top_3p.ENABLE_ZICCLSM=0 \
		-o $(EXEC_TOP_3P_NO_ZICCLSM_SIM_BUILD) \
		$(EXEC_SRCS) $(EXCEPT_SRCS) $(ARITH_DEPS) $(STAGE_SRCS) \
		tb/tb_exec_top_3p.sv

$(LSU_MISALIGNED_SIM_BUILD): tb/tb_lsu_misaligned.sv \
		rtl/core/exec/lsu/misaligned.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_lsu_misaligned \
		-o $(LSU_MISALIGNED_SIM_BUILD) \
		rtl/core/exec/lsu/misaligned.v tb/tb_lsu_misaligned.sv

$(LSQ_SIM_BUILD): $(LSQ_SIM_SRCS) rtl/core/exec/lsq.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(LSQ_SIM_BUILD) \
		rtl/core/exec/lsq.v $(LSQ_SIM_SRCS)

$(LSU_ATOMICS_SIM_BUILD): $(LSU_ATOMICS_SIM_SRCS) \
		rtl/core/exec/lsu/atomics.v rtl/core/exec/lsu/rv64-a.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(LSU_ATOMICS_SIM_BUILD) \
		rtl/core/exec/lsu/atomics.v rtl/core/exec/lsu/rv64-a.v \
		$(LSU_ATOMICS_SIM_SRCS)

$(EXEC_PIPE_MEM_TIMEOUT_SIM_BUILD): tb/tb_exec_pipe_mem_timeout.sv \
	rtl/core/exec/exec_pipe_mem.v rtl/core/exec/lsu/rv64-i.v \
	rtl/core/exec/lsu/rv64-a.v rtl/core/except/except.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_exec_pipe_mem_timeout \
		-o $(EXEC_PIPE_MEM_TIMEOUT_SIM_BUILD) \
		rtl/core/exec/exec_pipe_mem.v rtl/core/exec/lsu/rv64-i.v \
		rtl/core/exec/lsu/rv64-a.v rtl/core/except/except.v \
		tb/tb_exec_pipe_mem_timeout.sv

$(EXEC_LSU_RV64I_SIM_BUILD): $(EXEC_LSU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_LSU_RV64I_SIM_BUILD) $(EXEC_LSU_RV64I_SIM_SRCS)

$(EXEC_LSU_RV64A_SIM_BUILD): $(EXEC_LSU_RV64A_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_LSU_RV64A_SIM_BUILD) $(EXEC_LSU_RV64A_SIM_SRCS)

$(ATOMIC_CONTEXT_SIM_BUILD): $(ATOMIC_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ATOMIC_CONTEXT_SIM_BUILD) $(ATOMIC_CONTEXT_SIM_SRCS) $(CORE_SRCS)

$(EXEC_BR_SIM_BUILD): $(EXEC_BR_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BR_SIM_BUILD) $(EXEC_BR_SIM_SRCS)

$(EXEC_BP_SIM_BUILD): $(EXEC_BP_SIM_SRCS) $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_SIM_BUILD) rtl/core/exec/bp/bp.v $(EXEC_BP_SIM_SRCS)

$(EXEC_BP_GSHARE_BTB_SIM_BUILD): tb/tb_exec_bp_gshare_btb.sv $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_GSHARE_BTB_SIM_BUILD) \
		rtl/core/exec/bp/bp.v tb/tb_exec_bp_gshare_btb.sv

$(EXEC_BP_TAGGED_SPEC_SIM_BUILD): tb/tb_exec_bp_tagged_speculation.sv $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_TAGGED_SPEC_SIM_BUILD) \
		rtl/core/exec/bp/bp.v tb/tb_exec_bp_tagged_speculation.sv

$(EXEC_BP_MODES78_SIM_BUILD): tb/tb_exec_bp_modes78.sv $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_MODES78_SIM_BUILD) \
		rtl/core/exec/bp/bp.v tb/tb_exec_bp_modes78.sv

$(EXEC_FPU_RV64FD_SIM_BUILD): $(EXEC_FPU_RV64FD_SIM_SRCS) $(FPU_SRCS) \
		$(FP_ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_FPU_RV64FD_SIM_BUILD) \
		$(EXEC_FPU_RV64FD_SIM_SRCS)

$(RV64I_VEC_SIM_BUILD): $(RV64I_VEC_SIM_SRCS) $(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_rv64i_vec \
		-o $(RV64I_VEC_SIM_BUILD) $(VEC_REG_SRCS) $(RV64I_VEC_SIM_SRCS)

$(EXEC_VEC_SIM_BUILD): $(EXEC_VEC_SIM_SRCS) $(VEC_EXEC_SRCS) $(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_exec_vec \
		-o $(EXEC_VEC_SIM_BUILD) $(VEC_EXEC_SRCS) $(VEC_REG_SRCS) \
		$(EXEC_VEC_SIM_SRCS)

$(EXEC_VEC_LSU_SIM_BUILD): $(EXEC_VEC_LSU_SIM_SRCS) $(VEC_LSU_SRCS) \
		$(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_exec_vec_lsu \
		-o $(EXEC_VEC_LSU_SIM_BUILD) $(VEC_LSU_SRCS) $(VEC_REG_SRCS) \
		$(EXEC_VEC_LSU_SIM_SRCS)

$(VEC_CACHE_SIM_BUILD): $(VEC_CACHE_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_vec_sram_cache \
		-o $(VEC_CACHE_SIM_BUILD) $(VEC_CACHE_SIM_SRCS)

$(VEC_CACHE_AXI_SIM_BUILD): $(VEC_CACHE_BUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_vec_cache_bus \
		-Ptb_vec_cache_bus.BUS_TYPE=0 \
		-Ptb_vec_cache_bus.BUS_DATA_WIDTH=512 \
		-Ptb_vec_cache_bus.CACHE_BUS_DATA_WIDTH=512 \
		-o $(VEC_CACHE_AXI_SIM_BUILD) $(COMPLEX_BUS_SRCS) \
		$(VEC_CACHE_BUS_SIM_SRCS)

$(VEC_CACHE_WB_SIM_BUILD): $(VEC_CACHE_BUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_vec_cache_bus \
		-Ptb_vec_cache_bus.BUS_TYPE=1 \
		-Ptb_vec_cache_bus.BUS_DATA_WIDTH=64 \
		-o $(VEC_CACHE_WB_SIM_BUILD) $(COMPLEX_BUS_SRCS) \
		$(VEC_CACHE_BUS_SIM_SRCS)

$(VEC_CACHE_WB_512_SIM_BUILD): $(VEC_CACHE_BUS_SIM_SRCS) \
		$(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_vec_cache_bus \
		-Ptb_vec_cache_bus.BUS_TYPE=1 \
		-Ptb_vec_cache_bus.BUS_DATA_WIDTH=512 \
		-o $(VEC_CACHE_WB_512_SIM_BUILD) $(COMPLEX_BUS_SRCS) \
		$(VEC_CACHE_BUS_SIM_SRCS)

$(VEC_TEST_TOP_SIM_BUILD): $(VEC_TEST_TOP_SIM_SRCS) $(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_test_top \
		-o $(VEC_TEST_TOP_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_TEST_TOP_SIM_SRCS)

$(VEC_MATMUL_SIM_BUILD): $(VEC_MATMUL_SIM_SRCS) $(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_matmul \
		-o $(VEC_MATMUL_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_MATMUL_SIM_SRCS)

$(VEC_MATMUL_BF16_SIM_BUILD): $(VEC_MATMUL_BF16_SIM_SRCS) \
		$(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_matmul_bf16 \
		-o $(VEC_MATMUL_BF16_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_MATMUL_BF16_SIM_SRCS)
