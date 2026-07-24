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

yosys-timing-alu-rv64i-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/alu/report.sh rv64i

yosys-timing-frontend:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/frontend/report.sh

yosys-timing-frontend-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/frontend/report.sh

yosys-resources-core-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_CORE_RESOURCE_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/core/resources.sh
