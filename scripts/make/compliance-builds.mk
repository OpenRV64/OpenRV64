# Icarus and Verilator compliance-harness build recipes.

$(COMPLIANCE_1P_M_BUILD): tb/tb_compliance_1p.sv rtl/openrv64_top.sv \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_1p \
		-Ptb_compliance_1p.ENABLE_RV64M=1 -o $@ \
		rtl/openrv64_top.sv $(CORE_SRCS) tb/tb_compliance_1p.sv

$(COMPLIANCE_1P_I_BUILD): tb/tb_compliance_1p.sv rtl/openrv64_top.sv \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_1p \
		-Ptb_compliance_1p.ENABLE_RV64M=0 -o $@ \
		rtl/openrv64_top.sv $(CORE_SRCS) tb/tb_compliance_1p.sv

$(COMPLIANCE_3P_M_BUILD): tb/tb_compliance_3p.sv tb/tb_top_axi_3p.sv \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) $(ISA_SRCS) \
		$(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_3p \
		-Ptb_compliance_3p.ENABLE_RV64M=1 -o $@ \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		tb/tb_top_axi_3p.sv tb/tb_compliance_3p.sv

$(COMPLIANCE_3P_I_BUILD): tb/tb_compliance_3p.sv tb/tb_top_axi_3p.sv \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) $(ISA_SRCS) \
		$(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_3p \
		-Ptb_compliance_3p.ENABLE_RV64M=0 -o $@ \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		tb/tb_top_axi_3p.sv tb/tb_compliance_3p.sv

$(COMPLIANCE_PLATFORM_M_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_platform \
		-Ptb_compliance_platform.ENABLE_RV64M=1 -o $@ \
		$(CORE_SRCS) $(PLATFORM_SRCS) tb/tb_compliance_platform.sv

$(COMPLIANCE_PLATFORM_I_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	iverilog -g2012 -Wall -Irtl -s tb_compliance_platform \
		-Ptb_compliance_platform.ENABLE_RV64M=0 -o $@ \
		$(CORE_SRCS) $(PLATFORM_SRCS) tb/tb_compliance_platform.sv

$(COMPLIANCE_1P_M_VLT_BUILD): tb/tb_compliance_1p.sv rtl/openrv64_top.sv \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_1p -GENABLE_RV64M=1 \
		--Mdir $(dir $@) rtl/openrv64_top.sv $(CORE_SRCS) \
		tb/tb_compliance_1p.sv

$(COMPLIANCE_1P_I_VLT_BUILD): tb/tb_compliance_1p.sv rtl/openrv64_top.sv \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_1p -GENABLE_RV64M=0 \
		--Mdir $(dir $@) rtl/openrv64_top.sv $(CORE_SRCS) \
		tb/tb_compliance_1p.sv

$(COMPLIANCE_3P_M_VLT_BUILD): tb/tb_compliance_3p.sv tb/tb_top_axi_3p.sv \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) $(ISA_SRCS) \
		$(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_3p -GENABLE_RV64M=1 \
		--Mdir $(dir $@) rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		tb/tb_top_axi_3p.sv tb/tb_compliance_3p.sv

$(COMPLIANCE_3P_I_VLT_BUILD): tb/tb_compliance_3p.sv tb/tb_top_axi_3p.sv \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) $(ISA_SRCS) \
		$(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_3p -GENABLE_RV64M=0 \
		--Mdir $(dir $@) rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		tb/tb_top_axi_3p.sv tb/tb_compliance_3p.sv

$(COMPLIANCE_PLATFORM_M_VLT_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_platform -GENABLE_RV64M=1 \
		--Mdir $(dir $@) $(CORE_SRCS) $(PLATFORM_SRCS) \
		tb/tb_compliance_platform.sv

$(COMPLIANCE_PLATFORM_I_VLT_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_platform -GENABLE_RV64M=0 \
		--Mdir $(dir $@) $(CORE_SRCS) $(PLATFORM_SRCS) \
		tb/tb_compliance_platform.sv

$(COMPLIANCE_PLATFORM_3P_M_VLT_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_platform -GENABLE_RV64M=1 \
		-GBACKEND_CONFIG=2 -GISSUE_WINDOW=1 -GSPECULATION_WINDOW=1 \
		-GL2_BYTES=262144 -GL2_WAYS=8 \
		--Mdir $(dir $@) $(CORE_SRCS) $(PLATFORM_SRCS) \
		tb/tb_compliance_platform.sv

$(COMPLIANCE_PLATFORM_3P_I_VLT_BUILD): tb/tb_compliance_platform.sv \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -j 0 -Irtl \
		--top-module tb_compliance_platform -GENABLE_RV64M=0 \
		-GBACKEND_CONFIG=2 -GISSUE_WINDOW=1 -GSPECULATION_WINDOW=1 \
		-GL2_BYTES=262144 -GL2_WAYS=8 \
		--Mdir $(dir $@) $(CORE_SRCS) $(PLATFORM_SRCS) \
		tb/tb_compliance_platform.sv

$(COMPLIANCE_SMOKE_ELF): verification/compliance/smoke/smoke.S \
		verification/compliance/smoke/link.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mcmodel=medany -mno-relax -nostdlib -nostartfiles -static \
		-Wl,--build-id=none -T verification/compliance/smoke/link.ld \
		-o $@ verification/compliance/smoke/smoke.S

$(COMPLIANCE_SMOKE_MEMH64): $(COMPLIANCE_SMOKE_ELF) tools/elf2mem.py
	$(PYTHON) tools/elf2mem.py $< $@ --base 0x80000000 \
		--size 0x100000 --word-bytes 8 \
		--manifest $(COMPLIANCE_SMOKE_DIR)/smoke-64.json

$(COMPLIANCE_SMOKE_MEMH256): $(COMPLIANCE_SMOKE_ELF) tools/elf2mem.py
	$(PYTHON) tools/elf2mem.py $< $@ --base 0x80000000 \
		--size 0x100000 --word-bytes 32 \
		--manifest $(COMPLIANCE_SMOKE_DIR)/smoke-256.json
