# Yosys timing and resource-report workflows.

XC7K480T_3P_OUTPUT_DIR ?= build/fpga/xc7k480t/core-3p
XC7K480T_3P_PART ?= xc7k480tffg1156-2
XC7K480T_3P_XDC ?= synth/fpga/xc7k480t/default.xdc
XC7K480T_3P_EDIF := $(XC7K480T_3P_OUTPUT_DIR)/openrv64_core_3p.edif
XC7K480T_3P_JSON := $(XC7K480T_3P_OUTPUT_DIR)/openrv64_core_3p.json
XC7K480T_3P_STUB := $(XC7K480T_3P_OUTPUT_DIR)/openrv64_core_3p_stub.v
XC7K480T_3P_UTILIZATION_REPORT := \
	$(XC7K480T_3P_OUTPUT_DIR)/utilization.rpt
XC7K480T_3P_TIMING_REPORT := $(XC7K480T_3P_OUTPUT_DIR)/timing_synth.rpt
XC7K480T_MODULE_STATS_OUTPUT_DIR ?= build/fpga/xc7k480t/module-stats
XC7K480T_MODULE_STATS_JOBS ?= 8
XC7K480T_MODULE_STATS_MODULE ?=

fpga-xc7k480t-3p-yosys:
	OUT_DIR='$(XC7K480T_3P_OUTPUT_DIR)' \
		OUTPUT_EDIF='$(XC7K480T_3P_EDIF)' \
		OUTPUT_JSON='$(XC7K480T_3P_JSON)' \
		OUTPUT_STUB='$(XC7K480T_3P_STUB)' \
		bash synth/fpga/xc7k480t/build_yosys_3p_core.sh

fpga-xc7k480t-3p-yosys-check:
	@test -s '$(XC7K480T_3P_EDIF)'
	@test -s '$(XC7K480T_3P_JSON)'
	@printf 'OPENRV64 XC7K480T 3P YOSYS CHECK PASS edif=%s json=%s\n' \
		'$(XC7K480T_3P_EDIF)' '$(XC7K480T_3P_JSON)'

fpga-xc7k480t-module-stats:
	python3 synth/fpga/xc7k480t/build_module_stats.py \
		--output-dir '$(XC7K480T_MODULE_STATS_OUTPUT_DIR)' \
		--jobs '$(XC7K480T_MODULE_STATS_JOBS)' $(if $(XC7K480T_MODULE_STATS_MODULE),--module '$(XC7K480T_MODULE_STATS_MODULE)',)

fpga-xc7k480t-module-stats-check:
	@test -s '$(XC7K480T_MODULE_STATS_OUTPUT_DIR)/summary.md'
	@printf 'OPENRV64 XC7K480T MODULE STATS CHECK PASS summary=%s\n' \
		'$(XC7K480T_MODULE_STATS_OUTPUT_DIR)/summary.md'

fpga-xc7k480t-3p-utilization: fpga-xc7k480t-3p-yosys
	$(FPGA_VIVADO) -mode batch -nojournal -nolog \
		-source synth/fpga/xc7k480t/report_vivado_3p_utilization.tcl \
		-tclargs '$(XC7K480T_3P_EDIF)' '$(XC7K480T_3P_XDC)' \
		'$(XC7K480T_3P_OUTPUT_DIR)' '$(XC7K480T_3P_PART)'

fpga-xc7k480t-3p-utilization-check:
	@test -s '$(XC7K480T_3P_UTILIZATION_REPORT)'
	@test -s '$(XC7K480T_3P_TIMING_REPORT)'
	@printf 'OPENRV64 XC7K480T 3P UTILIZATION CHECK PASS part=%s report=%s\n' \
		'$(XC7K480T_3P_PART)' '$(XC7K480T_3P_UTILIZATION_REPORT)'

yosys-timing-alu:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh all

yosys-timing-alu-rv64i:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh rv64i

yosys-timing-alu-rv64m:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh rv64m

sky130-liberty: $(SKY130_LIBERTY)
	printf '%s  %s\n' "$(SKY130_LIBERTY_SHA256)" "$(SKY130_LIBERTY)" | sha256sum -c -

$(SKY130_LIBERTY):
	mkdir -p $(dir $@)
	$(CURL) -L --fail --silent --show-error -o $@.tmp $(SKY130_LIBERTY_URL)
	printf '%s  %s\n' "$(SKY130_LIBERTY_SHA256)" "$@.tmp" | sha256sum -c -
	mv $@.tmp $@

nangate45-liberty:
	CURL="$(CURL)" bash synth/nangate45/fetch-liberty.sh "$(abspath $(NANGATE45_LIBERTY))"

yosys-timing-alu-rv64i-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/alu/report.sh rv64i

yosys-timing-alu-rv64i-nangate45: nangate45-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(abspath $(NANGATE45_LIBERTY))" ABC_CONSTR="$(abspath $(NANGATE45_ABC_CONSTR))" bash synth/alu/report.sh rv64i

yosys-timing-frontend:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/frontend/report.sh

yosys-timing-frontend-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/frontend/report.sh

yosys-timing-frontend-nangate45: nangate45-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(abspath $(NANGATE45_LIBERTY))" ABC_CONSTR="$(abspath $(NANGATE45_ABC_CONSTR))" bash synth/frontend/report.sh

yosys-resources-core-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_CORE_RESOURCE_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/core/resources.sh

yosys-resources-core-4pf-fd-nangate45: nangate45-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(abspath $(YOSYS_CORE_4PF_NANGATE45_REPORT_DIR))" LIBERTY="$(abspath $(NANGATE45_LIBERTY))" ABC_CONSTR="$(abspath $(NANGATE45_ABC_CONSTR))" bash synth/nangate45/report-core-4pf.sh fd

yosys-resources-core-4pf-nofd-nangate45: nangate45-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(abspath $(YOSYS_CORE_4PF_NANGATE45_REPORT_DIR))" LIBERTY="$(abspath $(NANGATE45_LIBERTY))" ABC_CONSTR="$(abspath $(NANGATE45_ABC_CONSTR))" bash synth/nangate45/report-core-4pf.sh nofd

yosys-resources-core-4pf-nangate45: \
	yosys-resources-core-4pf-fd-nangate45 \
	yosys-resources-core-4pf-nofd-nangate45
