# Prefetch-characterization configuration.
#
# Each configurable workload gets a configuration-specific filename.  This
# keeps Make's timestamp model honest when sweeping build-time parameters.

PREFETCH_ASFLAGS := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -nostdlib -nostartfiles
PREFETCH_I_ASFLAGS := -march=rv64i_zicsr_zifencei -mabi=lp64 \
	-mcmodel=medany -mno-relax -nostdlib -nostartfiles
PREFETCH_CFLAGS := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -msmall-data-limit=0 -O2 -g -Wall -Wextra -Werror \
	-ffreestanding -fno-builtin -fno-common -fno-pic \
	-fno-stack-protector -fno-asynchronous-unwind-tables
PREFETCH_PIPELINE_TRACE ?= 0
PREFETCH_ENGINE ?= verilator
PREFETCH_FETCH_ALT_LOOKASIDE ?= 0
PREFETCH_L1D_ENABLE ?= 1
PREFETCH_L1D_MAX_STRIDE_LINES ?= 64
PREFETCH_L1D_STREAMS ?= 2
PREFETCH_L1D_DISTANCE ?= 1
PREFETCH_L1D_ADAPTIVE_ENABLE ?= 1
PREFETCH_L1D_MAX_DISTANCE ?= 4
PREFETCH_L1D_QUEUE_LINES ?= 4
PREFETCH_L1D_OUTSTANDING ?= 4
PREFETCH_L1D_DEMAND_RESERVE ?= 2
ifeq ($(filter $(PREFETCH_ENGINE),icarus verilator),)
$(error PREFETCH_ENGINE must be icarus or verilator)
endif
ifeq ($(filter $(PREFETCH_L1D_ENABLE),0 1),)
$(error PREFETCH_L1D_ENABLE must be 0 or 1)
endif
ifeq ($(filter $(PREFETCH_L1D_ADAPTIVE_ENABLE),0 1),)
$(error PREFETCH_L1D_ADAPTIVE_ENABLE must be 0 or 1)
endif
ifeq ($(filter $(PREFETCH_L1D_STREAMS),1 2 3 4),)
$(error PREFETCH_L1D_STREAMS must be 1 through 4)
endif
ifeq ($(filter $(AXI_3P_FREELOADER),0 1),)
$(error AXI_3P_FREELOADER must be 0 or 1)
endif

# The path captures every elaboration-time control used by the performance
# harness. Distinct parameter sweeps therefore cannot silently reuse a stale
# Verilator binary.
PREFETCH_VERILATOR_TAG := bp$(AXI_3P_PERF_BP_TYPE)-ras$(AXI_3P_PERF_BP_RAS_ENABLE)x$(AXI_3P_PERF_BP_RAS_DEPTH)-bi$(AXI_3P_PERF_BP_BIMODAL_ENTRIES)x$(AXI_3P_PERF_BP_BIMODAL_COUNTER_BITS)x$(AXI_3P_PERF_BP_BIMODAL_UPDATE_DEPTH)-gs$(AXI_3P_PERF_BP_GSHARE_ENTRIES)x$(AXI_3P_PERF_BP_GSHARE_COUNTER_BITS)-btb$(AXI_3P_PERF_BP_BTB_ENTRIES)x$(AXI_3P_PERF_BP_BTB_TAG_BITS)-if$(AXI_3P_PERF_BP_INFLIGHT_DEPTH)-rd$(AXI_3P_RETIRE_DEPTH)-cf$(AXI_3P_COMPLETION_FORWARD_MASK)-bf$(AXI_3P_BRANCH_FORWARD_MASK)-ff$(AXI_3P_FULL_FORWARDING)-rw$(AXI_3P_RELAX_WAW)-rh$(AXI_3P_RELAX_HAZARDS)-iw$(AXI_3P_ISSUE_WINDOW)-sw$(AXI_3P_SPECULATION_WINDOW)-ps$(AXI_3P_POSTED_STORES)-fb$(AXI_3P_FREE_BRANCHES)-eq$(AXI_3P_EQ_BRANCH_PAIRING)-or$(AXI_3P_ORACLE_BRANCHES)-fi$(AXI_3P_FREE_L1_REFILLS)-fii$(AXI_3P_FREE_L1I_REFILLS)-fid$(AXI_3P_FREE_L1D_REFILLS)-fl$(AXI_3P_FREELOADER)x$(AXI_3P_FREELOADER_LATENCY)-fa$(PREFETCH_FETCH_ALT_LOOKASIDE)-dp$(PREFETCH_L1D_ENABLE)x$(PREFETCH_L1D_MAX_STRIDE_LINES)x$(PREFETCH_L1D_STREAMS)x$(PREFETCH_L1D_DISTANCE)x$(PREFETCH_L1D_ADAPTIVE_ENABLE)x$(PREFETCH_L1D_MAX_DISTANCE)x$(PREFETCH_L1D_QUEUE_LINES)x$(PREFETCH_L1D_OUTSTANDING)x$(PREFETCH_L1D_DEMAND_RESERVE)
PREFETCH_VERILATOR_DIR := build/verilator/prefetch-3p-axi/$(PREFETCH_VERILATOR_TAG)
PREFETCH_VERILATOR_BUILD := $(PREFETCH_VERILATOR_DIR)/prefetch_3p_axi_tb

STREAM_KERNEL ?= triad
STREAM_BYTES ?= 65536
STREAM_KERNEL_ID := $(strip $(if $(filter copy,$(STREAM_KERNEL)),0,\
	$(if $(filter scale,$(STREAM_KERNEL)),1,\
	$(if $(filter add,$(STREAM_KERNEL)),2,\
	$(if $(filter triad,$(STREAM_KERNEL)),3,)))))
ifeq ($(STREAM_KERNEL_ID),)
$(error STREAM_KERNEL must be copy, scale, add, or triad)
endif
STREAM_TAG := $(STREAM_KERNEL)-$(STREAM_BYTES)
STREAM_ELF := sw/stream/stream-$(STREAM_TAG).elf
STREAM_BIN := sw/stream/stream-$(STREAM_TAG).bin
STREAM_MAP := sw/stream/stream-$(STREAM_TAG).map
STREAM_DISASM := sw/stream/stream-$(STREAM_TAG).disasm
STREAM_VM_ELF := sw/stream/stream-$(STREAM_TAG)-vm.elf
STREAM_VM_BIN := sw/stream/stream-$(STREAM_TAG)-vm.bin
STREAM_VM_MAP := sw/stream/stream-$(STREAM_TAG)-vm.map
STREAM_VM_DISASM := sw/stream/stream-$(STREAM_TAG)-vm.disasm
STREAM_VM_MEMH := sim/stream-$(STREAM_TAG)-vm.memh
STREAM_MEASURE_END = $(shell $(RISCV_NM) -n $(STREAM_ELF) | \
	awk '$$3 == "stream_measure_end" { print $$1 }')
STREAM_VM_MEASURE_END = $(shell $(RISCV_NM) -n $(STREAM_VM_ELF) | \
	awk '$$3 == "stream_measure_end" { print $$1 }')
STREAM_VM_DONE = $(shell $(RISCV_NM) -n $(STREAM_VM_ELF) | \
	awk '$$3 == "openrv64_runtime_done" { print $$1 }')
STREAM_PASS := 53545245414d4f4b
STREAM_MEMH_BYTES := 0x40000
STREAM_MEMH_WORDS := 8192
STREAM_VM_MEMH_BYTES := 0x44000
STREAM_VM_MEMH_WORDS := 8704
STREAM_MAX_CYCLES ?= 10000000
STREAM_DDR3_BP_TYPE ?= $(BP_TYPE_DEFAULT)
STREAM_DDR3_FETCH_ALT_LOOKASIDE ?= 3
STREAM_DDR3_RETIRE_DEPTH ?= 16
STREAM_DDR3_ISSUE_WINDOW ?= 1
STREAM_DDR3_SPECULATION_WINDOW ?= 1
STREAM_DDR3_POSTED_STORES ?= 1
STREAM_MEMORY_TIMING_MODEL ?= 0
STREAM_TIMED_REQUIRE_ARGS ?= +require_ddr3_overlap
STORE_EXTENSION_VM_ELF := sw/store-extension/store-extension-sv39.elf
STORE_EXTENSION_VM_BIN := sw/store-extension/store-extension-sv39.bin
STORE_EXTENSION_VM_MAP := sw/store-extension/store-extension-sv39.map
STORE_EXTENSION_VM_DISASM := sw/store-extension/store-extension-sv39.disasm
STORE_EXTENSION_VM_MEMH := sim/store-extension-sv39.memh
STORE_EXTENSION_VM_DONE = $(shell $(RISCV_NM) -n \
	$(STORE_EXTENSION_VM_ELF) | awk \
	'$$3 == "openrv64_runtime_done" { print $$1 }')
STORE_EXTENSION_VM_MEMH_BYTES := 0x44000
STORE_EXTENSION_VM_MEMH_WORDS := 8704
STORE_EXTENSION_VM_MAX_CYCLES ?= 2000000
A53_STREAM_ELF := sim/a53/stream-$(STREAM_TAG)-se.elf
A53_STREAM_MAP := sim/a53/stream-$(STREAM_TAG)-se.map
A53_STREAM_DISASM := sim/a53/stream-$(STREAM_TAG)-se.disasm
A53_STREAM_OUTDIR ?= sim/a53/gem5-hpi-stream-$(STREAM_TAG)
A53_STREAM_STATS := $(A53_STREAM_OUTDIR)/stats.txt
A53_STREAM_REPORT := $(A53_STREAM_OUTDIR)/report.txt

STRIDE_BYTES ?= 64
ifeq ($(filter $(STRIDE_BYTES),64 128 256 1024 4096),)
$(error STRIDE_BYTES must be 64, 128, 256, 1024, or 4096)
endif
STRIDE_ELF := sw/stride/stride-$(STRIDE_BYTES).elf
STRIDE_BIN := sw/stride/stride-$(STRIDE_BYTES).bin
STRIDE_MAP := sw/stride/stride-$(STRIDE_BYTES).map
STRIDE_DISASM := sw/stride/stride-$(STRIDE_BYTES).disasm
STRIDE_MEASURE_END = $(shell $(RISCV_NM) -n $(STRIDE_ELF) | \
	awk '$$3 == "stride_measure_end" { print $$1 }')
STRIDE_PASS := 5354524944454f4b
STRIDE_MEMH_BYTES := 0x10000
STRIDE_MEMH_WORDS := 2048
STRIDE_MAX_CYCLES ?= 10000000

STENCIL_ELF := sw/stride/stencil5.elf
STENCIL_BIN := sw/stride/stencil5.bin
STENCIL_MAP := sw/stride/stencil5.map
STENCIL_DISASM := sw/stride/stencil5.disasm
STENCIL_MEASURE_END = $(shell $(RISCV_NM) -n $(STENCIL_ELF) | \
	awk '$$3 == "stencil_measure_end" { print $$1 }')
STENCIL_PASS := 5354454e355f4f4b
STENCIL_MEMH_BYTES := 0x20000
STENCIL_MEMH_WORDS := 4096
STENCIL_MAX_CYCLES ?= 10000000

ICACHE_PATTERN ?= branch
ICACHE_BYTES ?= 65536
ICACHE_PATTERN_ID := $(strip $(if $(filter fallthrough,$(ICACHE_PATTERN)),0,\
	$(if $(filter branch,$(ICACHE_PATTERN)),1,\
	$(if $(filter call,$(ICACHE_PATTERN)),2,))))
ifeq ($(ICACHE_PATTERN_ID),)
$(error ICACHE_PATTERN must be fallthrough, branch, or call)
endif
ifeq ($(filter $(ICACHE_BYTES),4096 16384 65536 262144),)
$(error ICACHE_BYTES must be 4096, 16384, 65536, or 262144)
endif
ICACHE_TAG := $(ICACHE_PATTERN)-$(ICACHE_BYTES)
ICACHE_ELF := sw/icache/icache-$(ICACHE_TAG).elf
ICACHE_BIN := sw/icache/icache-$(ICACHE_TAG).bin
ICACHE_MAP := sw/icache/icache-$(ICACHE_TAG).map
ICACHE_DISASM := sw/icache/icache-$(ICACHE_TAG).disasm
ICACHE_MEASURE_END = $(shell $(RISCV_NM) -n $(ICACHE_ELF) | \
	awk '$$3 == "icache_measure_end" { print $$1 }')
ICACHE_PASS := 4943414348454f4b
ICACHE_MEMH_BYTES := 0x80000
ICACHE_MEMH_WORDS := 16384
ICACHE_MAX_CYCLES ?= 10000000

LZ4_ELF := sw/lz4/lz4.elf
LZ4_BIN := sw/lz4/lz4.bin
LZ4_MAP := sw/lz4/lz4.map
LZ4_DISASM := sw/lz4/lz4.disasm
LZ4_MEASURE_END = $(shell $(RISCV_NM) -n $(LZ4_ELF) | \
	awk '$$3 == "lz4_measure_end" { print $$1 }')
LZ4_PASS := 4c5a345f5f4f4b21
LZ4_MEMH_BYTES := 0x20000
LZ4_MEMH_WORDS := 4096
LZ4_MAX_CYCLES ?= 10000000
