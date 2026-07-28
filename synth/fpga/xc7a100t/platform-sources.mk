OPENRV64_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)

include $(OPENRV64_ROOT)/scripts/make/sources.mk

XC7_PLATFORM_SRCS := $(filter-out \
	rtl/soc/bus/memory.v, \
	$(PLATFORM_SRCS))
XC7_TARGET_SRCS := \
	synth/fpga/xc7a100t/soc_memory_fpga.sv \
	synth/fpga/xc7a100t/mig_native_memory.sv \
	synth/fpga/xc7a100t/mig_native_memory_cdc.sv

.PHONY: print-platform-sources

print-platform-sources:
	@for source in $(CORE_SRCS) $(XC7_PLATFORM_SRCS) $(XC7_TARGET_SRCS); do \
		printf '%s\n' "$(OPENRV64_ROOT)/$$source"; \
	done
