# Yosys timing and resource-report workflows.

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
