# Introspection targets used by tools/run-linux-3p.sh.
#
# This fragment is deliberately not included by the top-level Makefile.  The
# run wrapper loads it after Makefile so these targets see the same effective
# command-line overrides and derived values as the real build.

OPENRV64_LINUX_RUN_CONFIG_VARIABLES := $(sort \
	$(filter OPENSBI_3P_%,$(.VARIABLES)) \
	OPENSBI_BUILD_DIR \
	OPENSBI_SOURCE_DIR \
	OPENSBI_ARTIFACT_DIR \
	OPENSBI_MEMORY_SIZE \
	OPENSBI_FDT_ADDR \
	OPENSBI_REF \
	OPENSBI_CROSS_COMPILE \
	OPENSBI_DEBUG \
	OPENSBI_JOBS \
	RISCV_BARE_CROSS_COMPILE \
	$(filter LINUX_%,$(.VARIABLES)) \
	VERILATOR \
	PYTHON)

OPENRV64_LINUX_RUN_INPUTS := $(sort \
	$(OPENRV64_MAKEFILES) \
	$(OPENSBI_SIM_SRCS) \
	$(PLATFORM_SRCS) \
	$(CORE_SRCS) \
	$(ISA_SRCS) \
	$(ARITH_DEPS) \
	$(BP_DEPS) \
	tb/verilator_checkpoint_main.cpp \
	tools/build-opensbi.sh \
	tools/bin2mem.py \
	sw/opensbi.dts \
	sw/opensbi_defconfig \
	sw/opensbi_trampoline.S \
	sw/opensbi_trampoline.ld \
	sw/opensbi_payload.S \
	sw/opensbi_payload.ld \
	$(LINUX_IMAGE))

OPENRV64_LINUX_SMP_RUN_CONFIG_VARIABLES := $(sort \
	$(filter OPENSBI_1H_LINUX_%,$(.VARIABLES)) \
	$(filter OPENSBI_2H_LINUX_%,$(.VARIABLES)) \
	$(filter OPENSBI_4H_%,$(.VARIABLES)) \
	$(filter OPENSBI_SMP_LINUX_%,$(.VARIABLES)) \
	CORE_4H_3P_L1D_PREFETCH_ENABLE \
	CORE_4H_3P_M_MODE_PREFETCH_ENABLE \
	CORE_4H_3P_L1D_SYNC_TAG_LOOKUP \
	CORE_4H_3P_L1D_SYNC_STORE_EXTENSION \
	OPENSBI_3P_ENABLE_ZBB \
	OPENSBI_3P_ADVERTISE_ZBB \
	OPENSBI_3P_ADVERTISE_ZICCLSM \
	OPENSBI_SOURCE_DIR \
	$(filter LINUX_%,$(.VARIABLES)) \
	VERILATOR \
	PYTHON)

OPENRV64_LINUX_SMP_RUN_INPUTS := $(sort \
	$(OPENRV64_MAKEFILES) \
	$(CORE_3P_AXI_SRCS) \
	rtl/complex/protocol/line_crossbar.v \
	$(ICX_L2_SRCS) \
	$(ICX_COHERENT_SRCS) \
	$(COMPLEX_BUS_SRCS) \
	$(AXI_DDR3_SRCS) \
	$(ROM_SRCS) \
	$(CLINT_SRCS) \
	$(PLIC_SRCS) \
	$(UART_SRCS) \
	$(OPENSBI_4H_HELD_HARNESS_SOURCE) \
	tb/tb_4h_3p.sv \
	tb/verilator_4h_checkpoint_main.cpp \
	tools/build-opensbi.sh \
	tools/bin2mem.py \
	sw/opensbi_trampoline.S \
	sw/opensbi_trampoline.ld \
	$(LINUX_IMAGE))

.PHONY: openrv64-linux-run-config openrv64-linux-run-inputs \
	openrv64-linux-smp-run-config openrv64-linux-smp-run-inputs

openrv64-linux-run-config:
	$(info OPENRV64_LINUX_RUN_CONFIG_V1)
	$(foreach variable,$(OPENRV64_LINUX_RUN_CONFIG_VARIABLES),$(info $(variable)=$($(variable))))
	@:

openrv64-linux-run-inputs:
	$(info OPENRV64_LINUX_RUN_INPUTS_V1)
	$(foreach input,$(OPENRV64_LINUX_RUN_INPUTS),$(info $(input)))
	@:

openrv64-linux-smp-run-config:
	$(info OPENRV64_LINUX_SMP_RUN_CONFIG_V1)
	$(foreach variable,$(OPENRV64_LINUX_SMP_RUN_CONFIG_VARIABLES),$(info $(variable)=$($(variable))))
	@:

openrv64-linux-smp-run-inputs:
	$(info OPENRV64_LINUX_SMP_RUN_INPUTS_V1)
	$(foreach input,$(OPENRV64_LINUX_SMP_RUN_INPUTS),$(info $(input)))
	@:
