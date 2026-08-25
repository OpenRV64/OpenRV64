REPO_ROOT := $(CURDIR)
OUT_DIR ?= build/fpga/xc7a100t/netlist-load-use
CORE_DCP ?= build/fpga/xc7a100t/experiments/1p-mem4-scoreboard-read-prune-core/openrv64_fpga_core.dcp
VIVADO ?= /home/bill/bin/vivado
IVERILOG ?= iverilog
VVP ?= vvp
YOSYS_XILINX_CELLS ?= /usr/share/yosys/xilinx/cells_sim.v

NETLIST := $(OUT_DIR)/openrv64_fpga_core_funcsim.v
SNAPSHOT := fpga_load_use_netlist_sim
NETLIST_SIM := $(OUT_DIR)/fpga_load_use_netlist.vvp

.PHONY: build run

build: $(NETLIST)

$(NETLIST): $(CORE_DCP) synth/fpga/xc7a100t/write_core_funcsim.tcl
	mkdir -p $(OUT_DIR)
	$(VIVADO) -mode batch -nojournal -nolog \
		-source synth/fpga/xc7a100t/write_core_funcsim.tcl \
		-tclargs $(CORE_DCP) $(NETLIST)

$(NETLIST_SIM): $(NETLIST) tb/tb_load_use_context.sv $(YOSYS_XILINX_CELLS)
	$(IVERILOG) -g2012 -Wall -DOPENRV64_LOAD_USE_NETLIST \
		-Irtl -s tb_load_use_context -o $(NETLIST_SIM) \
		$(YOSYS_XILINX_CELLS) tb/tb_load_use_context.sv $(NETLIST)

run: $(NETLIST_SIM)
	$(VVP) $(NETLIST_SIM)
