# SoC, platform, cache, interconnect, and firmware simulation builds.

$(TOP_SIM_BUILD): $(TOP_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TOP_SIM_BUILD) $(CORE_SRCS) $(TOP_SIM_SRCS)

$(PLATFORM_SIM_BUILD): $(PLATFORM_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PLATFORM_SIM_BUILD) $(CORE_SRCS) $(PLATFORM_SRCS) $(PLATFORM_SIM_SRCS)

$(RESET_SEQUENCER_SIM_BUILD): $(RESET_SEQUENCER_SIM_SRCS) $(RESET_SEQUENCER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RESET_SEQUENCER_SIM_BUILD) $(RESET_SEQUENCER_SRCS) $(RESET_SEQUENCER_SIM_SRCS)

$(UART_FIRMWARE_SIM_BUILD): $(UART_FIRMWARE_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(UART_FIRMWARE_SIM_SRCS)

$(UART_FIRMWARE_PERF_SIM_BUILD): FORCE $(UART_FIRMWARE_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_uart_firmware.BP_TYPE=$(UART_PERF_BP_TYPE) \
		-Ptb_uart_firmware.BP_RAS_ENABLE=$(UART_PERF_BP_RAS_ENABLE) \
		-Ptb_uart_firmware.BP_RAS_DEPTH=$(UART_PERF_BP_RAS_DEPTH) \
		-o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(UART_FIRMWARE_SIM_SRCS)

$(OPENSBI_SIM_BUILD): $(OPENSBI_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_VERILATOR_BUILD): $(OPENSBI_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(OPENSBI_VERILATOR_DIR)
	$(VERILATOR) --binary --timing -j 0 -Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-GMEMORY_BYTES=$(OPENSBI_PLATFORM_MEMORY_BYTES) \
		-GFDT_BASE_LO=$(OPENSBI_PLATFORM_FDT_BASE) \
		-Irtl --top-module tb_opensbi \
		-Mdir $(OPENSBI_VERILATOR_DIR) -o opensbi_tb \
		$(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD): \
		tb/verilator_checkpoint_main.cpp $(OPENSBI_SIM_SRCS) \
		$(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) \
		$(BP_DEPS)
	mkdir -p $(OPENSBI_3P_PLATFORM_VERILATOR_DIR)
	+$(VERILATOR) --cc --exe --build --no-timing --savable \
		-j $(OPENSBI_3P_PLATFORM_VERILATOR_BUILD_JOBS) \
		--threads $(OPENSBI_3P_PLATFORM_VERILATOR_THREADS) \
		-Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-DOPENRV64_VERILATOR_CHECKPOINT \
		-GBACKEND_CONFIG=2 \
		-GENABLE_ZICCLSM=$(OPENSBI_3P_ENABLE_ZICCLSM) \
		-GBP_TYPE=$(OPENSBI_3P_PLATFORM_BP_TYPE) \
		-GISSUE_WINDOW=$(OPENSBI_3P_PLATFORM_ISSUE_WINDOW) \
		-GSPECULATION_WINDOW=$(OPENSBI_3P_PLATFORM_SPECULATION_WINDOW) \
		-GRETIRE_DEPTH=$(OPENSBI_3P_PLATFORM_RETIRE_DEPTH) \
		-GPHYS_REG_COUNT=$(OPENSBI_3P_PLATFORM_PHYS_REG_COUNT) \
		-GSTORE_QUEUE_DEPTH=$(OPENSBI_3P_PLATFORM_STORE_QUEUE_DEPTH) \
		-GL2_BYTES=$(OPENSBI_3P_PLATFORM_L2_BYTES) \
		-GL2_WAYS=$(OPENSBI_3P_PLATFORM_L2_WAYS) \
		-GL2_MERGE_ENTRIES=$(OPENSBI_3P_PLATFORM_L2_MERGE_ENTRIES) \
		-GGENBUS_READ_BUFFER_DEPTH=$(OPENSBI_3P_PLATFORM_GENBUS_READ_DEPTH) \
		-GGENBUS_WRITE_BUFFER_DEPTH=$(OPENSBI_3P_PLATFORM_GENBUS_WRITE_DEPTH) \
		-GL2_TLB_ENTRIES=$(OPENSBI_3P_PLATFORM_L2_TLB_ENTRIES) \
		-GL2_TLB_WAYS=$(OPENSBI_3P_PLATFORM_L2_TLB_WAYS) \
		-GFETCH_CAROUSEL=$(OPENSBI_3P_PLATFORM_FETCH_CAROUSEL) \
		-GFETCH_ALT_LOOKASIDE=$(OPENSBI_3P_PLATFORM_FETCH_ALT_LOOKASIDE) \
		-GFETCH_ALT_CONFIDENCE_GATE=$(OPENSBI_3P_PLATFORM_FETCH_ALT_CONFIDENCE_GATE) \
		-GL1I_DEMAND_MSHRS=$(OPENSBI_3P_PLATFORM_L1I_DEMAND_MSHRS) \
		-GL1D_PREFETCH_ENABLE=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_ENABLE) \
		-GL1D_PREFETCH_MAX_DISTANCE=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_MAX_DISTANCE) \
		-GL1D_PREFETCH_QUEUE_LINES=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_QUEUE_LINES) \
		-GL1D_PREFETCH_OUTSTANDING=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_OUTSTANDING) \
		-GL1D_PREFETCH_DEMAND_RESERVE=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_DEMAND_RESERVE) \
		-GL1D_PREFETCH_PAGE_GATING=$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_PAGE_GATING) \
		-GCCX_BUS_TYPE=$(OPENSBI_3P_PLATFORM_BUS_TYPE) \
		-GCCX_BUS_DATA_WIDTH=$(OPENSBI_3P_PLATFORM_BUS_DATA_WIDTH) \
		-GDDR3_ENABLE=$(OPENSBI_3P_PLATFORM_DDR3_ENABLE) \
		-GDDR3_READ_QUEUE_DEPTH=$(OPENSBI_3P_PLATFORM_DDR3_READ_QUEUE_DEPTH) \
		-GDDR3_WRITE_QUEUE_DEPTH=$(OPENSBI_3P_PLATFORM_DDR3_WRITE_QUEUE_DEPTH) \
		-GDDR3_COMMAND_QUEUE_DEPTH=$(OPENSBI_3P_PLATFORM_DDR3_COMMAND_QUEUE_DEPTH) \
		-GDDR3_BANK_ROW_SWIZZLE=$(OPENSBI_3P_PLATFORM_DDR3_BANK_ROW_SWIZZLE) \
		-GMEMORY_TIMING_MODEL=$(OPENSBI_3P_PLATFORM_MEMORY_TIMING_MODEL) \
		-GMEMORY_BYTES=$(OPENSBI_3P_PLATFORM_MEMORY_BYTES) \
		-GFDT_BASE_LO=$(OPENSBI_3P_PLATFORM_FDT_BASE) \
		-Irtl --top-module tb_opensbi \
		-Mdir $(OPENSBI_3P_PLATFORM_VERILATOR_DIR) \
		-o opensbi_3p_platform_tb \
		$(abspath tb/verilator_checkpoint_main.cpp) \
		$(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_3P_VERILATOR_BUILD): tb/tb_top_axi_3p.sv rtl/openrv64_top_3p.v \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
	mkdir -p $(OPENSBI_3P_VERILATOR_DIR)
	$(VERILATOR) --binary --timing \
		--verilate-jobs 0 --build-jobs 0 \
		--output-split 20000 --output-split-cfuncs 2000 \
		-Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-GRAM_ZERO_INIT_LINES=0 \
		-GENABLE_ZICCLSM=$(OPENSBI_3P_ENABLE_ZICCLSM) \
		-GISSUE_WINDOW=$(OPENSBI_3P_ISSUE_WINDOW) \
		-GSPECULATION_WINDOW=$(OPENSBI_3P_SPECULATION_WINDOW) \
		-Irtl --top-module tb_top_axi_3p \
		-Mdir $(OPENSBI_3P_VERILATOR_DIR) -o opensbi_3p_axi_tb \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS) \
		tb/tb_top_axi_3p.sv

$(SW_TRACE_SIM_BUILD): FORCE $(SW_TRACE_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_sw_trace.ENABLE_FORWARDING=$(SW_FORWARDING) \
		-Ptb_sw_trace.ENABLE_LOAD_FORWARDING=$(SW_LOAD_FORWARDING) \
		-Ptb_sw_trace.BP_TYPE=$(SW_BP_TYPE) \
		-Ptb_sw_trace.BP_RAS_ENABLE=$(SW_BP_RAS_ENABLE) \
		-Ptb_sw_trace.BP_RAS_DEPTH=$(SW_BP_RAS_DEPTH) \
		-o $(SW_TRACE_SIM_BUILD) $(CORE_SRCS) $(SW_TRACE_SIM_SRCS)

$(CLINT_SIM_BUILD): $(CLINT_SIM_SRCS) $(CLINT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(CLINT_SIM_BUILD) $(CLINT_SRCS) $(CLINT_SIM_SRCS)

$(PLIC_SIM_BUILD): $(PLIC_SIM_SRCS) $(PLIC_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PLIC_SIM_BUILD) $(PLIC_SRCS) $(PLIC_SIM_SRCS)

$(UART_SIM_BUILD): $(UART_SIM_SRCS) $(UART_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(UART_SIM_BUILD) $(UART_SRCS) $(UART_SIM_SRCS)

$(GPIO_SIM_BUILD): $(GPIO_SIM_SRCS) $(GPIO_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(GPIO_SIM_BUILD) $(GPIO_SRCS) $(GPIO_SIM_SRCS)

$(TIMER_SIM_BUILD): $(TIMER_SIM_SRCS) $(TIMER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TIMER_SIM_BUILD) $(TIMER_SRCS) $(TIMER_SIM_SRCS)

$(ROM_SIM_BUILD): $(ROM_SIM_SRCS) $(ROM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ROM_SIM_BUILD) $(ROM_SRCS) $(ROM_SIM_SRCS)

$(MEMORY_SIM_BUILD): $(MEMORY_SIM_SRCS) $(MEMORY_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(MEMORY_SIM_BUILD) $(MEMORY_SRCS) $(MEMORY_SIM_SRCS)

$(MEM_CHANNEL_SIM_BUILD): $(MEM_CHANNEL_SIM_SRCS) $(MEM_CHANNEL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_mem_channel \
		-o $(MEM_CHANNEL_SIM_BUILD) $(MEM_CHANNEL_SRCS) \
		$(MEM_CHANNEL_SIM_SRCS)

$(L2_AXI_DDR3_SIM_BUILD): $(L2_AXI_DDR3_SIM_SRCS) \
		$(CORE_COMPLEX_SRCS) $(AXI_DDR3_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l2_axi_ddr3 \
		-o $(L2_AXI_DDR3_SIM_BUILD) $(CORE_COMPLEX_SRCS) \
		$(AXI_DDR3_SRCS) $(L2_AXI_DDR3_SIM_SRCS)

$(MESH_ROUTER_SIM_BUILD): $(MESH_ROUTER_SIM_SRCS) $(MESH_ROUTER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_mesh_router_tile \
		-o $(MESH_ROUTER_SIM_BUILD) $(MESH_ROUTER_SRCS) \
		$(MESH_ROUTER_SIM_SRCS)

$(SOC_BUS_SIM_BUILD): $(SOC_BUS_SIM_SRCS) $(SOC_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(SOC_BUS_SIM_BUILD) rtl/soc/bus/decode.v $(SOC_BUS_SIM_SRCS)

$(CORE_BUS_SIM_BUILD): $(CORE_BUS_SIM_SRCS) $(BUS_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(CORE_BUS_SIM_BUILD) $(BUS_SRCS) $(CORE_BUS_SIM_SRCS)

$(CCX_PROTOCOL_1H_SIM_BUILD): $(CCX_PROTOCOL_1H_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_1h \
		-o $(CCX_PROTOCOL_1H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_1H_SIM_SRCS)

$(CCX_PROTOCOL_2H_SIM_BUILD): $(CCX_PROTOCOL_NH_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_nh \
		-Ptb_ccx_protocol_nh.NUM_HARTS=2 \
		-o $(CCX_PROTOCOL_2H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_NH_SIM_SRCS)

$(CCX_PROTOCOL_4H_SIM_BUILD): $(CCX_PROTOCOL_NH_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_nh \
		-Ptb_ccx_protocol_nh.NUM_HARTS=4 \
		-o $(CCX_PROTOCOL_4H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_NH_SIM_SRCS)

$(CCX_COHERENT_2H_SIM_BUILD): tb/tb_ccx_coherent_control.sv \
		$(CCX_COHERENT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_coherent_control \
		-Ptb_ccx_coherent_control.NUM_HARTS=2 \
		-o $(CCX_COHERENT_2H_SIM_BUILD) $(CCX_COHERENT_SRCS) \
		tb/tb_ccx_coherent_control.sv

$(CCX_COHERENT_4H_SIM_BUILD): tb/tb_ccx_coherent_control.sv \
		$(CCX_COHERENT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_coherent_control \
		-Ptb_ccx_coherent_control.NUM_HARTS=4 \
		-o $(CCX_COHERENT_4H_SIM_BUILD) $(CCX_COHERENT_SRCS) \
		tb/tb_ccx_coherent_control.sv

$(CCX_COHERENT_PROTOCOL_2H_SIM_BUILD): \
		tb/tb_ccx_coherent_protocol.sv $(CCX_COHERENT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_coherent_protocol \
		-Ptb_ccx_coherent_protocol.NUM_HARTS=2 \
		-o $(CCX_COHERENT_PROTOCOL_2H_SIM_BUILD) \
		rtl/complex/protocol/defs.v $(CCX_COHERENT_SRCS) \
		tb/tb_ccx_coherent_protocol.sv

$(CCX_COHERENT_PROTOCOL_4H_SIM_BUILD): \
		tb/tb_ccx_coherent_protocol.sv $(CCX_COHERENT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_coherent_protocol \
		-Ptb_ccx_coherent_protocol.NUM_HARTS=4 \
		-o $(CCX_COHERENT_PROTOCOL_4H_SIM_BUILD) \
		rtl/complex/protocol/defs.v $(CCX_COHERENT_SRCS) \
		tb/tb_ccx_coherent_protocol.sv

$(CCX_4H_L1D_DIRECTORY_L2_SIM_BUILD): \
		tb/tb_ccx_4h_l1d_directory_l2.sv $(L1_CACHE_SRCS) \
		$(CCX_COHERENT_SRCS) $(CCX_L2_SRCS) \
		rtl/complex/protocol/line_crossbar.v \
		rtl/core/exec/lsu/rv64-a.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_4h_l1d_directory_l2 \
		-o $(CCX_4H_L1D_DIRECTORY_L2_SIM_BUILD) \
		$(L1_CACHE_SRCS) rtl/complex/protocol/line_crossbar.v \
		$(CCX_COHERENT_SRCS) $(CCX_L2_SRCS) \
		rtl/core/exec/lsu/rv64-a.v \
		tb/tb_ccx_4h_l1d_directory_l2.sv

$(L1_CACHE_SIM_BUILD): $(L1_CACHE_SIM_SRCS) $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1_cache \
		-o $(L1_CACHE_SIM_BUILD) $(L1_CACHE_SRCS) $(L1_CACHE_SIM_SRCS)

$(L1D_PREFETCH_SIM_BUILD): tb/tb_l1d_prefetch.sv $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1d_prefetch \
		-o $(L1D_PREFETCH_SIM_BUILD) $(L1_CACHE_SRCS) \
		tb/tb_l1d_prefetch.sv

$(L1D_DEMAND_MSHR_SIM_BUILD): tb/tb_l1d_demand_mshr.sv $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1d_demand_mshr \
		-o $(L1D_DEMAND_MSHR_SIM_BUILD) $(L1_CACHE_SRCS) \
		tb/tb_l1d_demand_mshr.sv

$(L1D_STORE_ORDER_SIM_BUILD): tb/tb_l1d_store_order.sv $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1d_store_order \
		-o $(L1D_STORE_ORDER_SIM_BUILD) $(L1_CACHE_SRCS) \
		tb/tb_l1d_store_order.sv

$(L1D_STORE_BUFFER_SIM_BUILD): tb/tb_l1d_store_buffer.sv $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1d_store_buffer \
		-o $(L1D_STORE_BUFFER_SIM_BUILD) $(L1_CACHE_SRCS) \
		tb/tb_l1d_store_buffer.sv

$(CCX_L2_SIM_BUILD): $(CCX_L2_SIM_SRCS) $(CCX_L2_SRCS) \
		rtl/complex/protocol/defs.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_l2 \
		-o $(CCX_L2_SIM_BUILD) rtl/complex/protocol/defs.v \
		$(CCX_L2_SRCS) $(CCX_L2_SIM_SRCS)

$(GENBUS_AXI_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=0 -o $(GENBUS_AXI_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(GENBUS_WB_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=1 \
		-Ptb_genbus_interface.DOWN_WIDTH=64 \
		-o $(GENBUS_WB_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(GENBUS_WB_32_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=1 \
		-Ptb_genbus_interface.DOWN_WIDTH=32 \
		-o $(GENBUS_WB_32_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(GENBUS_WB_128_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=1 \
		-Ptb_genbus_interface.DOWN_WIDTH=128 \
		-o $(GENBUS_WB_128_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(GENBUS_WB_256_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=1 \
		-Ptb_genbus_interface.DOWN_WIDTH=256 \
		-o $(GENBUS_WB_256_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(GENBUS_WB_512_SIM_BUILD): $(GENBUS_SIM_SRCS) $(COMPLEX_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_genbus_interface \
		-Ptb_genbus_interface.BUS_TYPE=1 \
		-Ptb_genbus_interface.DOWN_WIDTH=512 \
		-o $(GENBUS_WB_512_SIM_BUILD) \
		$(COMPLEX_BUS_SRCS) $(GENBUS_SIM_SRCS)

$(CORE_COMPLEX_1H_AXI_SIM_BUILD): $(CORE_COMPLEX_SIM_SRCS) \
		$(CORE_COMPLEX_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_core_complex \
		-Ptb_core_complex.NUM_HARTS=1 -Ptb_core_complex.BUS_TYPE=0 \
		-o $(CORE_COMPLEX_1H_AXI_SIM_BUILD) $(CORE_COMPLEX_SRCS) \
		$(CORE_COMPLEX_SIM_SRCS)

$(CORE_COMPLEX_2H_AXI_SIM_BUILD): $(CORE_COMPLEX_SIM_SRCS) \
		$(CORE_COMPLEX_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_core_complex \
		-Ptb_core_complex.NUM_HARTS=2 -Ptb_core_complex.BUS_TYPE=0 \
		-o $(CORE_COMPLEX_2H_AXI_SIM_BUILD) $(CORE_COMPLEX_SRCS) \
		$(CORE_COMPLEX_SIM_SRCS)

$(CORE_COMPLEX_4H_WB_SIM_BUILD): $(CORE_COMPLEX_SIM_SRCS) \
		$(CORE_COMPLEX_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_core_complex \
		-Ptb_core_complex.NUM_HARTS=4 -Ptb_core_complex.BUS_TYPE=1 \
		-o $(CORE_COMPLEX_4H_WB_SIM_BUILD) $(CORE_COMPLEX_SRCS) \
		$(CORE_COMPLEX_SIM_SRCS)

$(CCX_BUS_SIM_BUILD): $(CCX_BUS_SIM_SRCS) $(BUS_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(CCX_BUS_SIM_BUILD) $(BUS_SRCS) $(CCX_BUS_SIM_SRCS)

$(CCX_L1I_SIM_BUILD): $(CCX_L1I_SIM_SRCS) $(BUS_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_l1i \
		-o $(CCX_L1I_SIM_BUILD) $(BUS_SRCS) $(CCX_L1I_SIM_SRCS)

$(L1I_TOP_SIM_BUILD): FORCE $(L1I_TOP_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_l1i_top \
		-Ptb_openrv64_l1i_top.CACHE_BYTES=$(L1I_TOP_CACHE_BYTES) \
		-Ptb_openrv64_l1i_top.WAYS=$(L1I_TOP_WAYS) \
		-Ptb_openrv64_l1i_top.PREFETCH_SLOTS=$(L1I_TOP_PREFETCH_SLOTS) \
		-o $(L1I_TOP_SIM_BUILD) $(L1I_TOP_SIM_SRCS)

$(TLB_SIM_BUILD): $(TLB_SIM_SRCS) rtl/core/bus/tlb.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TLB_SIM_BUILD) rtl/core/bus/tlb.v $(TLB_SIM_SRCS)

$(TLB_L2_SIM_BUILD): $(TLB_L2_SIM_SRCS) rtl/core/bus/tlb_l2.v \
		rtl/core/bus/tlb.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TLB_L2_SIM_BUILD) \
		rtl/core/bus/tlb.v rtl/core/bus/tlb_l2.v $(TLB_L2_SIM_SRCS)

$(PTW_SIM_BUILD): $(PTW_SIM_SRCS) rtl/core/bus/ptw.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PTW_SIM_BUILD) rtl/core/bus/ptw.v $(PTW_SIM_SRCS)
