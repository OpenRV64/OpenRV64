# Single-image Sv39 correctness and performance smoke test.

SV39_SMOKE_ENABLE_COREMARK ?= 1
SV39_SMOKE_ENABLE_BLAKE2S ?= 1
SV39_SMOKE_ENABLE_STREAM ?= 1
SV39_SMOKE_ENABLE_ATOMIC ?= 1
SV39_SMOKE_ENABLE_FENCE ?= 1
SV39_SMOKE_ENABLE_STORE_EXTENSION ?= 1

SV39_SMOKE_ENABLES := \
	$(SV39_SMOKE_ENABLE_COREMARK) \
	$(SV39_SMOKE_ENABLE_BLAKE2S) \
	$(SV39_SMOKE_ENABLE_STREAM) \
	$(SV39_SMOKE_ENABLE_ATOMIC) \
	$(SV39_SMOKE_ENABLE_FENCE) \
	$(SV39_SMOKE_ENABLE_STORE_EXTENSION)

ifneq ($(words $(filter 0 1,$(SV39_SMOKE_ENABLES))),6)
$(error SV39_SMOKE_ENABLE_* controls must each be 0 or 1)
endif

SV39_SMOKE_TAG := c$(SV39_SMOKE_ENABLE_COREMARK)-b$(SV39_SMOKE_ENABLE_BLAKE2S)-s$(SV39_SMOKE_ENABLE_STREAM)-a$(SV39_SMOKE_ENABLE_ATOMIC)-f$(SV39_SMOKE_ENABLE_FENCE)-e$(SV39_SMOKE_ENABLE_STORE_EXTENSION)
SV39_SMOKE_BUILD_DIR := build/sv39-smoke/$(SV39_SMOKE_TAG)
SV39_SMOKE_ELF := $(SV39_SMOKE_BUILD_DIR)/sv39-smoke.elf
SV39_SMOKE_BIN := $(SV39_SMOKE_BUILD_DIR)/sv39-smoke.bin
SV39_SMOKE_MEMH := $(SV39_SMOKE_BUILD_DIR)/sv39-smoke.memh
SV39_SMOKE_MAP := $(SV39_SMOKE_BUILD_DIR)/sv39-smoke.map
SV39_SMOKE_DISASM := $(SV39_SMOKE_BUILD_DIR)/sv39-smoke.disasm
SV39_SMOKE_IMAGE_BYTES := 0x44000
SV39_SMOKE_MEMH_WORDS := 8704
SV39_SMOKE_MAX_CYCLES ?= 2000000
SV39_SMOKE_PASS := 535633395f4f4b21
SV39_SMOKE_DONE = $(shell $(RISCV_NM) -n $(SV39_SMOKE_ELF) 2>/dev/null | \
	awk '$$3 == "openrv64_runtime_done" { print $$1 }')

SV39_SMOKE_CFLAGS := -march=rv64ima_zicsr_zifencei -mabi=lp64 \
	-mcmodel=medany -mno-relax -msmall-data-limit=0 -O2 -g \
	-Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common \
	-fno-pic -fno-stack-protector -fno-asynchronous-unwind-tables \
	-fno-strict-overflow -fconserve-stack -mstrict-align \
	-ffunction-sections -fdata-sections -nostdlib -nostartfiles \
	-DSV39_SMOKE_ENABLE_COREMARK=$(SV39_SMOKE_ENABLE_COREMARK) \
	-DSV39_SMOKE_ENABLE_BLAKE2S=$(SV39_SMOKE_ENABLE_BLAKE2S) \
	-DSV39_SMOKE_ENABLE_STREAM=$(SV39_SMOKE_ENABLE_STREAM) \
	-DSV39_SMOKE_ENABLE_ATOMIC=$(SV39_SMOKE_ENABLE_ATOMIC) \
	-DSV39_SMOKE_ENABLE_FENCE=$(SV39_SMOKE_ENABLE_FENCE) \
	-DSV39_SMOKE_ENABLE_STORE_EXTENSION=$(SV39_SMOKE_ENABLE_STORE_EXTENSION) \
	-DOPENRV64_STREAM_ENTRY=sv39_smoke_stream \
	-DOPENRV64_ATOMIC_ENTRY=sv39_smoke_atomic \
	-DOPENRV64_FENCE_BENCH_ENTRY=sv39_smoke_fence \
	-DOPENRV64_STORE_EXTENSION_ENTRY=sv39_smoke_store_extension

SV39_SMOKE_SRCS := \
	sw/runtime/sv39.S \
	sw/runtime/sv39_smoke.S \
	sw/coremark_loop.c \
	sw/blake2s/blake2s.c \
	sw/stream/stream.S \
	sw/atomic/atomic.S \
	sw/fence/fence_bench.S \
	sw/store-extension/store_extension_sv39.S

.PHONY: sw-sv39-smoke sim-sv39-smoke test-sv39-smoke

$(SV39_SMOKE_ELF): $(OPENRV64_MAKEFILES) $(SV39_SMOKE_SRCS) \
		sw/runtime/c_start.inc sw/runtime/openrv64-sv39.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(SV39_SMOKE_CFLAGS) \
		-Wa,--defsym,STREAM_KERNEL=3 \
		-Wa,--defsym,STREAM_BYTES=65536 \
		-Wa,--defsym,STREAM_VM=1 \
		-DBLAKE2S_BENCH_CALLS=16 \
		-DBLAKE2S_BLOCKS_PER_CALL=1 \
		-Wl,--build-id=none,--gc-sections,-Map,$(SV39_SMOKE_MAP) \
		-T sw/runtime/openrv64-sv39.ld -o $@ $(SV39_SMOKE_SRCS)

$(SV39_SMOKE_BIN): $(SV39_SMOKE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(SV39_SMOKE_MEMH): $(SV39_SMOKE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(SV39_SMOKE_IMAGE_BYTES) --word-bytes 32

$(SV39_SMOKE_DISASM): $(SV39_SMOKE_ELF)
	$(RISCV_OBJDUMP) -d -S -M no-aliases $< > $@

sw-sv39-smoke: $(SV39_SMOKE_ELF) $(SV39_SMOKE_BIN) \
		$(SV39_SMOKE_MEMH) $(SV39_SMOKE_DISASM)

sim-sv39-smoke: $(SV39_SMOKE_MEMH)
	test -n "$(SV39_SMOKE_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MEMH=$(SV39_SMOKE_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(SV39_SMOKE_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(SV39_SMOKE_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(SV39_SMOKE_PASS) +done_pc=$(SV39_SMOKE_DONE) +require_sv39 +require_timed_memory +report_sv39_smoke" \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=0

test-sv39-smoke: sim-sv39-smoke
