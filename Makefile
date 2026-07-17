TOP_SIM_BUILD := sim/openrv64_top_tb.vvp
DECODE_EARLY_SIM_BUILD := sim/decode_early_tb.vvp
DECODE_TOP_SIM_BUILD := sim/decode_top_tb.vvp
DECODE_IMM_SIM_BUILD := sim/decode_imm_tb.vvp
DECODE_ALU_SIM_BUILD := sim/decode_alu_tb.vvp
DECODE_LSU_SIM_BUILD := sim/decode_lsu_tb.vvp
DECODE_REG_ALU_SIM_BUILD := sim/decode_reg_alu_tb.vvp
DECODE_REG_LSU_SIM_BUILD := sim/decode_reg_lsu_tb.vvp
DECODE_BR_SIM_BUILD := sim/decode_br_tb.vvp
ISA_BITMANIP_SIM_BUILD := sim/isa_bitmanip_tb.vvp
STAGE_SIM_BUILD := sim/stage_tb.vvp
RV64I_GPR_SIM_BUILD := sim/rv64-i-gpr_tb.vvp
FETCH_SIM_BUILD := sim/fetch_tb.vvp
EXEC_ALU_RV64I_SIM_BUILD := sim/exec_alu_rv64-i_tb.vvp
EXEC_ALU_RV64M_SIM_BUILD := sim/exec_alu_rv64-m_tb.vvp
EXEC_LSU_RV64I_SIM_BUILD := sim/exec_lsu_rv64-i_tb.vvp
EXEC_BR_SIM_BUILD := sim/exec_br_tb.vvp
EXCEPT_SIM_BUILD := sim/except_tb.vvp
EXEC_SYSTEM_CSR_SIM_BUILD := sim/exec_system_csr_tb.vvp
DISPATCH_SIM_BUILD := sim/dispatch_tb.vvp
ISA_SRCS := rtl/core/isa/rv64-i.v rtl/core/isa/rv64-m.v \
	rtl/core/isa/rv64-zba.v rtl/core/isa/rv64-zbb.v \
	rtl/core/isa/rv64-zbc.v rtl/core/isa/rv64-zbs.v rtl/core/isa/rv64-b.v
DECODE_SRCS := rtl/core/decode/defs/early-defs.v rtl/core/decode/defs/alu-defs.v \
	rtl/core/decode/defs/lsu-defs.v rtl/core/decode/defs/br-defs.v \
	rtl/core/decode/early.v rtl/core/decode/decode_top.v rtl/core/decode/imm.v rtl/core/decode/alu.v \
	rtl/core/decode/lsu.v rtl/core/decode/br.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v
REG_SRCS := rtl/core/regs/rv64-i-gpr.v
FETCH_SRCS := rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch.v
DISPATCH_SRCS := rtl/core/dispatch/dispatch.v
EXEC_SRCS := rtl/core/exec/exec_top.v rtl/core/exec/alu/rv64-i.v rtl/core/exec/alu/rv64-m.v \
	rtl/core/exec/lsu/rv64-i.v \
	rtl/core/exec/br.v rtl/core/exec/system/csr.v
EXCEPT_SRCS := rtl/core/except/except.v
STAGE_SRCS := rtl/core/stage/stage.v
CORE_SRCS := rtl/core/rv64_top.v $(STAGE_SRCS) $(FETCH_SRCS) $(DECODE_SRCS) $(REG_SRCS) $(DISPATCH_SRCS) $(EXEC_SRCS) $(EXCEPT_SRCS)
TOP_SIM_SRCS := rtl/openrv64_top.sv tb/tb_openrv64_top.sv
DECODE_EARLY_SIM_SRCS := tb/tb_decode_early.sv
DECODE_TOP_SIM_SRCS := rtl/core/decode/early.v rtl/core/decode/imm.v \
	rtl/core/decode/alu.v rtl/core/decode/lsu.v rtl/core/decode/br.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v tb/tb_decode_top.sv
DECODE_IMM_SIM_SRCS := tb/tb_decode_imm.sv
DECODE_ALU_SIM_SRCS := tb/tb_decode_alu.sv
DECODE_LSU_SIM_SRCS := tb/tb_decode_lsu.sv
DECODE_REG_ALU_SIM_SRCS := tb/tb_decode_reg_alu.sv
DECODE_REG_LSU_SIM_SRCS := tb/tb_decode_reg_lsu.sv
DECODE_BR_SIM_SRCS := tb/tb_decode_br.sv
ISA_BITMANIP_SIM_SRCS := tb/tb_isa_bitmanip.sv
STAGE_SIM_SRCS := tb/tb_stage.sv
RV64I_GPR_SIM_SRCS := tb/tb_rv64-i-gpr.sv
FETCH_SIM_SRCS := tb/tb_fetch.sv
EXEC_ALU_RV64I_SIM_SRCS := tb/tb_exec_alu_rv64-i.sv
EXEC_ALU_RV64M_SIM_SRCS := tb/tb_exec_alu_rv64-m.sv
EXEC_LSU_RV64I_SIM_SRCS := tb/tb_exec_lsu_rv64-i.sv
EXEC_BR_SIM_SRCS := tb/tb_exec_br.sv
EXCEPT_SIM_SRCS := tb/tb_except.sv
EXEC_SYSTEM_CSR_SIM_SRCS := tb/tb_exec_system_csr.sv
DISPATCH_SIM_SRCS := tb/tb_dispatch.sv

.PHONY: sim sim-top sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-fetch sim-dispatch sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-lsu-rv64-i sim-exec-br sim-except sim-exec-system-csr clean

sim: sim-top sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-fetch sim-dispatch sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-lsu-rv64-i sim-exec-br sim-except sim-exec-system-csr

sim-top: $(TOP_SIM_BUILD)
	vvp $(TOP_SIM_BUILD)

sim-decode-early: $(DECODE_EARLY_SIM_BUILD)
	vvp $(DECODE_EARLY_SIM_BUILD)

sim-decode-top: $(DECODE_TOP_SIM_BUILD)
	vvp $(DECODE_TOP_SIM_BUILD)

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

sim-stage: $(STAGE_SIM_BUILD)
	vvp $(STAGE_SIM_BUILD)

sim-rv64-i-gpr: $(RV64I_GPR_SIM_BUILD)
	vvp $(RV64I_GPR_SIM_BUILD)

sim-fetch: $(FETCH_SIM_BUILD)
	vvp $(FETCH_SIM_BUILD)

sim-dispatch: $(DISPATCH_SIM_BUILD)
	vvp $(DISPATCH_SIM_BUILD)

sim-exec-alu-rv64-i: $(EXEC_ALU_RV64I_SIM_BUILD)
	vvp $(EXEC_ALU_RV64I_SIM_BUILD)

sim-exec-alu-rv64-m: $(EXEC_ALU_RV64M_SIM_BUILD)
	vvp $(EXEC_ALU_RV64M_SIM_BUILD)

sim-exec-lsu-rv64-i: $(EXEC_LSU_RV64I_SIM_BUILD)
	vvp $(EXEC_LSU_RV64I_SIM_BUILD)

sim-exec-br: $(EXEC_BR_SIM_BUILD)
	vvp $(EXEC_BR_SIM_BUILD)

sim-except: $(EXCEPT_SIM_BUILD)
	vvp $(EXCEPT_SIM_BUILD)

sim-exec-system-csr: $(EXEC_SYSTEM_CSR_SIM_BUILD)
	vvp $(EXEC_SYSTEM_CSR_SIM_BUILD)

$(TOP_SIM_BUILD): $(TOP_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TOP_SIM_BUILD) $(CORE_SRCS) $(TOP_SIM_SRCS)

$(DECODE_EARLY_SIM_BUILD): $(DECODE_EARLY_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_EARLY_SIM_BUILD) $(DECODE_EARLY_SIM_SRCS)

$(DECODE_TOP_SIM_BUILD): $(DECODE_TOP_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_TOP_SIM_BUILD) $(DECODE_TOP_SIM_SRCS)

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

$(STAGE_SIM_BUILD): $(STAGE_SIM_SRCS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(STAGE_SIM_BUILD) $(STAGE_SIM_SRCS)

$(RV64I_GPR_SIM_BUILD): $(RV64I_GPR_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_SIM_BUILD) $(RV64I_GPR_SIM_SRCS)

$(FETCH_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_SIM_BUILD) $(FETCH_SIM_SRCS)

$(DISPATCH_SIM_BUILD): $(DISPATCH_SIM_SRCS) $(DISPATCH_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_SIM_BUILD) $(DISPATCH_SIM_SRCS)

$(EXEC_ALU_RV64I_SIM_BUILD): $(EXEC_ALU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64I_SIM_BUILD) $(EXEC_ALU_RV64I_SIM_SRCS)

$(EXEC_ALU_RV64M_SIM_BUILD): $(EXEC_ALU_RV64M_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64M_SIM_BUILD) $(EXEC_ALU_RV64M_SIM_SRCS)

$(EXEC_LSU_RV64I_SIM_BUILD): $(EXEC_LSU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_LSU_RV64I_SIM_BUILD) $(EXEC_LSU_RV64I_SIM_SRCS)

$(EXEC_BR_SIM_BUILD): $(EXEC_BR_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BR_SIM_BUILD) $(EXEC_BR_SIM_SRCS)

$(EXCEPT_SIM_BUILD): $(EXCEPT_SIM_SRCS) $(EXCEPT_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXCEPT_SIM_BUILD) $(EXCEPT_SIM_SRCS)

$(EXEC_SYSTEM_CSR_SIM_BUILD): $(EXEC_SYSTEM_CSR_SIM_SRCS) $(EXEC_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_SYSTEM_CSR_SIM_BUILD) $(EXEC_SYSTEM_CSR_SIM_SRCS)

clean:
	rm -rf sim
