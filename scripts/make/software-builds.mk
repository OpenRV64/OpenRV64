# Software artifact build recipes.

$(SMP_THREAD_PROBE_BIN): $(OPENRV64_MAKEFILES) sw/smp_thread_probe.S
	mkdir -p $(dir $@)
	$(RISCV_LINUX_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mno-relax -nostdlib -nostartfiles -static -no-pie \
		-Wl,--build-id=none,-e,_start,-z,noexecstack \
		-o $@ sw/smp_thread_probe.S

$(SMP_THREAD_TEST_SCRIPT): sw/smp-thread-test.sh
	mkdir -p $(dir $@)
	install -m 0755 $< $@

$(LINUX_USER_STRESS_BIN): $(OPENRV64_MAKEFILES) \
		sw/linux-user-tests/start.S \
		sw/linux-user-tests/openrv64_user_stress.c
	mkdir -p $(dir $@)
	$(RISCV_LINUX_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mno-relax -mcmodel=medany -O2 -g -Wall -Wextra -Werror \
		-ffreestanding -fno-builtin -fno-common -fno-pic \
		-fno-stack-protector -fno-asynchronous-unwind-tables \
		-ffunction-sections -fdata-sections -nostdlib -nostartfiles \
		-static -no-pie -Wl,--build-id=none,--gc-sections,-e,_start \
		-o $@ sw/linux-user-tests/start.S \
		sw/linux-user-tests/openrv64_user_stress.c

$(LINUX_USER_TEST_SCRIPT): sw/linux-user-tests/run.sh
	mkdir -p $(dir $@)
	install -m 0755 $< $@

$(LINUX_USER_PTHREAD_BIN): $(OPENRV64_MAKEFILES) \
		sw/linux-user-tests/pthread_lock_stress.c
	@test -n "$(RISCV_LINUX_PTHREAD_CC)" || { \
		echo "RISCV_LINUX_PTHREAD_CC must name an RV64IMA/lp64 pthread compiler"; \
		exit 1; \
	}
	@test -n "$(RISCV_LINUX_PTHREAD_SYSROOT)" || { \
		echo "RISCV_LINUX_PTHREAD_SYSROOT must name its static musl sysroot"; \
		exit 1; \
	}
	mkdir -p $(dir $@)
	$(RISCV_LINUX_PTHREAD_CC) -march=rv64ima_zicsr_zifencei -mabi=lp64 \
		-mno-relax -O2 -g -Wall -Wextra -Werror -static -pthread -no-pie \
		-nostdlib -nostartfiles -nodefaultlibs \
		$(RISCV_LINUX_PTHREAD_SYSROOT)/lib/crt1.o \
		$(RISCV_LINUX_PTHREAD_SYSROOT)/lib/crti.o \
		sw/linux-user-tests/pthread_lock_stress.c \
		-Wl,--build-id=none,--start-group -lc -lpthread -Wl,--end-group \
		$(RISCV_LINUX_PTHREAD_SYSROOT)/lib/crtn.o -o $@

$(UART_FIRMWARE_ELF): $(OPENRV64_MAKEFILES) sw/start.S sw/uart.c sw/openrv64.ld
	$(RISCV_CC) $(UART_FIRMWARE_CFLAGS) -nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map=$(UART_FIRMWARE_MAP) \
		-T sw/openrv64.ld -o $@ sw/start.S sw/uart.c

$(UART_FIRMWARE_BIN): $(UART_FIRMWARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_DAXPY_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/fp/daxpy.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FP_DAXPY_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FP_DAXPY_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/fp/daxpy.S

$(FP_DAXPY_BIN): $(FP_DAXPY_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_DAXPY_DISASM): $(FP_DAXPY_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FP_DAXPY_MEMH): $(FP_DAXPY_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FP_DAXPY_MEMH_BYTES) --word-bytes 32

$(FP_DAXPY_COMPUTE_ELF): $(OPENRV64_MAKEFILES) \
		sw/runtime/bare.S sw/runtime/c_start.inc \
		sw/fp/daxpy_compute.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FP_DAXPY_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FP_DAXPY_COMPUTE_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/fp/daxpy_compute.S

$(FP_DAXPY_COMPUTE_BIN): $(FP_DAXPY_COMPUTE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_DAXPY_COMPUTE_DISASM): $(FP_DAXPY_COMPUTE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FP_DAXPY_COMPUTE_MEMH): $(FP_DAXPY_COMPUTE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FP_DAXPY_COMPUTE_MEMH_BYTES) --word-bytes 32

$(FP_DAXPY_STORE_ELF): $(OPENRV64_MAKEFILES) \
		sw/runtime/bare.S sw/runtime/c_start.inc \
		sw/fp/daxpy_store.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FP_DAXPY_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FP_DAXPY_STORE_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/fp/daxpy_store.S

$(FP_DAXPY_STORE_BIN): $(FP_DAXPY_STORE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_DAXPY_STORE_DISASM): $(FP_DAXPY_STORE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FP_DAXPY_STORE_MEMH): $(FP_DAXPY_STORE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FP_DAXPY_STORE_MEMH_BYTES) --word-bytes 32

$(FP_FMADD32_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/fp/fmadd32.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FP_FMADD32_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FP_FMADD32_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/fp/fmadd32.S

$(FP_FMADD32_BIN): $(FP_FMADD32_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_FMADD32_DISASM): $(FP_FMADD32_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FP_FMADD32_MEMH): $(FP_FMADD32_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FP_FMADD32_MEMH_BYTES) --word-bytes 32

$(FP_FAULTS_ELF): $(OPENRV64_MAKEFILES) sw/fp/faults.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(FP_FAULTS_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(FP_FAULTS_MAP) \
		-T sw/openrv64.ld -o $@ sw/fp/faults.S

$(FP_FAULTS_BIN): $(FP_FAULTS_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(FP_FAULTS_DISASM): $(FP_FAULTS_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(FP_FAULTS_MEMH): $(FP_FAULTS_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(FP_FAULTS_MEMH_BYTES) --word-bytes 32

$(COREMARK_LOOP_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/coremark_loop_start.S \
		sw/coremark_loop.c sw/openrv64.ld
	$(RISCV_CC) $(COREMARK_LOOP_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_LOOP_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S \
		sw/coremark_loop_start.S \
		sw/coremark_loop.c

$(COREMARK_LOOP_BIN): $(COREMARK_LOOP_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

COREMARK_BARE_UPSTREAM_SRCS := \
	sw/coremark/upstream/core_list_join.c \
	sw/coremark/upstream/core_matrix.c \
	sw/coremark/upstream/core_state.c \
	sw/coremark/upstream/core_util.c
COREMARK_BARE_PORT_SRCS := \
	sw/coremark/openrv64/core_main_wrapper.c \
	sw/coremark/openrv64/core_portme.c \
	sw/coremark/openrv64/ee_printf.c \
	sw/coremark/openrv64/runner.c

$(COREMARK_BARE_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/openrv64.ld \
		sw/coremark/upstream/core_main.c \
		sw/coremark/upstream/coremark.h \
		sw/coremark/openrv64/core_portme.h \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_BARE_CFLAGS) -nostdlib \
		-Isw/coremark/openrv64 -Isw/coremark/upstream \
		-DTOTAL_DATA_SIZE=$(COREMARK_BARE_TOTAL_DATA_SIZE) \
		-DITERATIONS=$(COREMARK_BARE_ITERATIONS) \
		-DCOREMARK_CLOCKS_PER_SEC=$(COREMARK_BARE_CLOCKS_PER_SEC)UL \
		-DCOREMARK_UART_ENABLE=$(COREMARK_BARE_UART_ENABLE) \
		-DCOREMARK_UART_DIVISOR=$(COREMARK_BARE_UART_DIVISOR) \
		-DFLAGS_STR='"-O2 -march=rv64im_zicsr -mabi=lp64"' \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_BARE_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)

$(COREMARK_BARE_BIN): $(COREMARK_BARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(COREMARK_BARE_MEMH): $(COREMARK_BARE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(COREMARK_BARE_MEMH_BYTES) --word-bytes 32

$(COREMARK_BARE_DISASM): $(COREMARK_BARE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(COREMARK_BARE_SMOKE_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/openrv64.ld \
		sw/coremark/upstream/core_main.c \
		sw/coremark/upstream/coremark.h \
		sw/coremark/openrv64/core_portme.h \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_BARE_CFLAGS) -nostdlib \
		-Isw/coremark/openrv64 -Isw/coremark/upstream \
		-DTOTAL_DATA_SIZE=$(COREMARK_BARE_TOTAL_DATA_SIZE) \
		-DITERATIONS=1 -DCOREMARK_CLOCKS_PER_SEC=1UL \
		-DCOREMARK_UART_ENABLE=0 \
		-DCOREMARK_UART_DIVISOR=$(COREMARK_BARE_UART_DIVISOR) \
		-DFLAGS_STR='"functional-smoke-not-reportable"' \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_BARE_SMOKE_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)

$(COREMARK_BARE_SMOKE_BIN): $(COREMARK_BARE_SMOKE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(COREMARK_BARE_SMOKE_MEMH): $(COREMARK_BARE_SMOKE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(COREMARK_BARE_MEMH_BYTES) --word-bytes 32

$(COREMARK_BARE_SMOKE_DISASM): $(COREMARK_BARE_SMOKE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(COREMARK_BARE_RUN_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/openrv64.ld \
		sw/coremark/upstream/core_main.c \
		sw/coremark/upstream/coremark.h \
		sw/coremark/openrv64/core_portme.h \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_BARE_CFLAGS) -nostdlib \
		-Isw/coremark/openrv64 -Isw/coremark/upstream \
		-DTOTAL_DATA_SIZE=$(COREMARK_BARE_TOTAL_DATA_SIZE) \
		-DITERATIONS=$(COREMARK_BARE_ITERATIONS) \
		-DCOREMARK_CLOCKS_PER_SEC=$(COREMARK_BARE_CLOCKS_PER_SEC)UL \
		-DCOREMARK_UART_ENABLE=0 -DCOREMARK_RETURN_REPORT=1 \
		-DFLAGS_STR='"-O2 -march=rv64im_zicsr -mabi=lp64"' \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_BARE_RUN_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S \
		$(COREMARK_BARE_UPSTREAM_SRCS) $(COREMARK_BARE_PORT_SRCS)

$(COREMARK_BARE_RUN_BIN): $(COREMARK_BARE_RUN_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(COREMARK_BARE_RUN_MEMH): $(COREMARK_BARE_RUN_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(COREMARK_BARE_MEMH_BYTES) --word-bytes 32

$(COREMARK_BARE_RUN_DISASM): $(COREMARK_BARE_RUN_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_3P_MAGIC_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/coremark_loop_start.S \
		sw/coremark_loop.c sw/openrv64-magic.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_LOOP_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_3P_MAGIC_MAP) \
		-T sw/openrv64-magic.ld -o $@ sw/runtime/bare.S \
		sw/coremark_loop_start.S \
		sw/coremark_loop.c

$(CORE_3P_MAGIC_BIN): $(CORE_3P_MAGIC_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_3P_MAGIC_MEMH): $(CORE_3P_MAGIC_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_3P_MAGIC_SRAM_BYTES) --word-bytes 32

$(CORE_3P_VM_ELF): $(OPENRV64_MAKEFILES) sw/runtime/sv39.S \
		sw/runtime/c_start.inc sw/runtime/openrv64-sv39.ld \
		sw/coremark_loop_start.S sw/coremark_loop.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_3P_VM_MAP) \
		-T sw/runtime/openrv64-sv39.ld -o $@ sw/runtime/sv39.S \
		sw/coremark_loop_start.S sw/coremark_loop.c

$(CORE_3P_VM_BIN): $(CORE_3P_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_3P_VM_MEMH): $(CORE_3P_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_3P_VM_MEMH_BYTES) --word-bytes 32

$(CORE_3P_VM_DISASM): $(CORE_3P_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_VM_ELF): $(OPENRV64_MAKEFILES) sw/coremark_4h_vm_start.S \
		sw/coremark_loop.c sw/openrv64-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_VM_MAP) \
		-T sw/openrv64-vm.ld -o $@ sw/coremark_4h_vm_start.S \
		sw/coremark_loop.c

$(CORE_4H_VM_TEMPLATE_BIN): $(CORE_4H_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_VM_BIN): $(CORE_4H_VM_TEMPLATE_BIN) \
		tools/make_4h_sv39_image.py
	$(PYTHON) tools/make_4h_sv39_image.py $< $@

$(CORE_4H_VM_MEMH): $(CORE_4H_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_VM_MEMH_BYTES) --word-bytes 64

$(CORE_4H_VM_DISASM): $(CORE_4H_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c \
		sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c

$(CORE_4H_SHARED_VM_TEMPLATE_BIN): $(CORE_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_SHARED_VM_BIN): $(CORE_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(CORE_4H_SHARED_VM_MEMH): $(CORE_4H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(CORE_4H_SHARED_VM_DISASM): $(CORE_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_BARE_ELF): $(OPENRV64_MAKEFILES) \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c \
		sw/openrv64-4h-bare.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -DOPENRV64_4H_BARE -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_BARE_MAP) \
		-T sw/openrv64-4h-bare.ld -o $@ \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c

$(CORE_4H_BARE_BIN): $(CORE_4H_BARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_BARE_MEMH): $(CORE_4H_BARE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_BARE_MEMH_BYTES) --word-bytes 64

$(CORE_4H_BARE_DISASM): $(CORE_4H_BARE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_BARE_PERF_ELF): $(OPENRV64_MAKEFILES) \
		sw/coremark_4h_bare_perf_start.S sw/coremark_loop.c \
		sw/openrv64-4h-bare-perf.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) \
		-DOPENRV64_4H_PERF_ITERATIONS=$(CORE_4H_BARE_PERF_ITERATIONS) \
		-nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_BARE_PERF_MAP) \
		-T sw/openrv64-4h-bare-perf.ld -o $@ \
		sw/coremark_4h_bare_perf_start.S sw/coremark_loop.c

$(CORE_4H_BARE_PERF_BIN): $(CORE_4H_BARE_PERF_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_BARE_PERF_MEMH): $(CORE_4H_BARE_PERF_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_BARE_PERF_MEMH_BYTES) --word-bytes 64

$(CORE_4H_BARE_PERF_DISASM): $(CORE_4H_BARE_PERF_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

define COHERENCE_PERF_BUILD
$(call coherence_perf_elf,$1,$2): $(OPENRV64_MAKEFILES) \
		sw/coherence_4h_shared_perf.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $$(dir $$@)
	$$(RISCV_CC) $$(ATOMIC_SOC_ASFLAGS) \
		-DOPENRV64_COHERENCE_CASE=$(call coherence_perf_case_id,$2) \
		-DOPENRV64_COHERENCE_HARTS=$1 \
		-DOPENRV64_COHERENCE_ITERATIONS=$$(COHERENCE_PERF_ITERATIONS) \
		-nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(call coherence_perf_map,$1,$2) \
		-T sw/openrv64-4h-shared-vm.ld -o $$@ \
		sw/coherence_4h_shared_perf.S

$(call coherence_perf_template_bin,$1,$2): \
		$(call coherence_perf_elf,$1,$2)
	$$(RISCV_OBJCOPY) -O binary $$< $$@

$(call coherence_perf_bin,$1,$2): \
		$(call coherence_perf_template_bin,$1,$2) \
		tools/make_shared_sv39_image.py
	$$(PYTHON) tools/make_shared_sv39_image.py $$< $$@

$(call coherence_perf_memh_512,$1,$2): \
		$(call coherence_perf_bin,$1,$2) tools/bin2mem.py
	$$(PYTHON) tools/bin2mem.py $$< $$@ \
		--size $$(COHERENCE_PERF_MEMH_BYTES) --word-bytes 64

$(call coherence_perf_memh_256,$1,$2): \
		$(call coherence_perf_bin,$1,$2) tools/bin2mem.py
	$$(PYTHON) tools/bin2mem.py $$< $$@ \
		--size $$(COHERENCE_PERF_MEMH_BYTES) --word-bytes 32

$(call coherence_perf_disasm,$1,$2): \
		$(call coherence_perf_elf,$1,$2)
	$$(RISCV_OBJDUMP) -d -M no-aliases $$< > $$@
endef

$(foreach harts,$(COHERENCE_PERF_HART_COUNTS),\
	$(foreach case,$(COHERENCE_PERF_CASES),\
		$(eval $(call COHERENCE_PERF_BUILD,$(harts),$(case)))))

$(foreach case,$(ATOMIC_LATENCY_CASES),\
	$(eval $(call COHERENCE_PERF_BUILD,1,$(case))))

$(foreach case,$(ATOMIC_LATENCY_4H_CASES),\
	$(eval $(call COHERENCE_PERF_BUILD,4,$(case))))

$(ATOMIC_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/atomic_4h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(ATOMIC_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/atomic_4h_shared_vm.S

$(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN): $(ATOMIC_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ATOMIC_4H_SHARED_VM_BIN): $(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(ATOMIC_4H_SHARED_VM_MEMH): $(ATOMIC_4H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ATOMIC_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(ATOMIC_4H_SHARED_VM_DISASM): $(ATOMIC_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(TICKET_LOCK_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/ticket_lock_4h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-DOPENRV64_TICKET_LOCK_TARGET=$(TICKET_LOCK_4H_SHARED_VM_TARGET) \
		-Wl,--build-id=none,--gc-sections,-Map,$(TICKET_LOCK_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/ticket_lock_4h_shared_vm.S

$(TICKET_LOCK_4H_SHARED_VM_TEMPLATE_BIN): \
		$(TICKET_LOCK_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(TICKET_LOCK_4H_SHARED_VM_BIN): \
		$(TICKET_LOCK_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(TICKET_LOCK_4H_SHARED_VM_MEMH): $(TICKET_LOCK_4H_SHARED_VM_BIN) \
		tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(TICKET_LOCK_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(TICKET_LOCK_4H_SHARED_VM_DISASM): $(TICKET_LOCK_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(TLBI_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/tlbi_4h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(TLBI_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/tlbi_4h_shared_vm.S

$(TLBI_4H_SHARED_VM_TEMPLATE_BIN): $(TLBI_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(TLBI_4H_SHARED_VM_BIN): $(TLBI_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py \
		--tlbi-test $< $@

$(TLBI_4H_SHARED_VM_MEMH): $(TLBI_4H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(TLBI_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(TLBI_4H_SHARED_VM_DISASM): $(TLBI_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(IPI_2H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/ipi_2h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-DOPENRV64_IPI_ROUNDS=$(IPI_2H_SHARED_VM_ROUNDS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(IPI_2H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/ipi_2h_shared_vm.S

$(IPI_2H_SHARED_VM_TEMPLATE_BIN): $(IPI_2H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(IPI_2H_SHARED_VM_BIN): $(IPI_2H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(IPI_2H_SHARED_VM_MEMH): $(IPI_2H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(IPI_2H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(IPI_2H_SHARED_VM_DISASM): $(IPI_2H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(WFI_MAILBOX_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/wfi_mailbox_4h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-DOPENRV64_WFI_MAILBOX_ROUNDS=$(WFI_MAILBOX_4H_SHARED_VM_ROUNDS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(WFI_MAILBOX_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/wfi_mailbox_4h_shared_vm.S

$(WFI_MAILBOX_4H_SHARED_VM_TEMPLATE_BIN): \
		$(WFI_MAILBOX_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(WFI_MAILBOX_4H_SHARED_VM_BIN): \
		$(WFI_MAILBOX_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(WFI_MAILBOX_4H_SHARED_VM_MEMH): $(WFI_MAILBOX_4H_SHARED_VM_BIN) \
		tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(WFI_MAILBOX_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(WFI_MAILBOX_4H_SHARED_VM_DISASM): $(WFI_MAILBOX_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ZERO_VM_ELF): $(OPENRV64_MAKEFILES) sw/zero/zero_sv39.S \
		sw/zero/openrv64-zero-sv39.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(ZERO_VM_MAP) \
		-T sw/zero/openrv64-zero-sv39.ld -o $@ \
		sw/zero/zero_sv39.S

$(ZERO_VM_BIN): $(ZERO_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ZERO_VM_MEMH): $(ZERO_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ZERO_VM_MEMH_BYTES) --word-bytes 32

$(ZERO_VM_DISASM): $(ZERO_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_SOC_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/atomic/atomic.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(ATOMIC_SOC_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/atomic/atomic.S

$(ATOMIC_SOC_BIN): $(ATOMIC_SOC_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ATOMIC_SOC_DISASM): $(ATOMIC_SOC_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_SOC_MEMH): $(ATOMIC_SOC_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ATOMIC_SOC_MEMH_BYTES) --word-bytes 32

$(MEMCPY_4K_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/memcpy/memcpy.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) -DOPENRV64_RUNTIME_NO_BSS_CLEAR \
		-Wa,--defsym,MEMCPY_BYTES=4096 \
		-Wl,--build-id=none,-Map,$(MEMCPY_4K_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/memcpy/memcpy.S

$(MEMCPY_4K_BIN): $(MEMCPY_4K_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_4K_DISASM): $(MEMCPY_4K_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(MEMCPY_64K_ELF): $(OPENRV64_MAKEFILES) sw/runtime/bare.S \
		sw/runtime/c_start.inc sw/memcpy/memcpy.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) -DOPENRV64_RUNTIME_NO_BSS_CLEAR \
		-Wa,--defsym,MEMCPY_BYTES=65536 \
		-Wl,--build-id=none,-Map,$(MEMCPY_64K_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S sw/memcpy/memcpy.S

$(MEMCPY_64K_BIN): $(MEMCPY_64K_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_64K_DISASM): $(MEMCPY_64K_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(MEMCPY_64K_VM_ELF): $(OPENRV64_MAKEFILES) sw/runtime/sv39.S \
		sw/runtime/c_start.inc sw/memcpy/memcpy.S \
		sw/runtime/openrv64-sv39.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) -DOPENRV64_RUNTIME_NO_BSS_CLEAR \
		-Wa,--defsym,MEMCPY_BYTES=65536 \
		-Wa,--defsym,MEMCPY_VM=1 \
		-Wl,--build-id=none,-Map,$(MEMCPY_64K_VM_MAP) \
		-T sw/runtime/openrv64-sv39.ld -o $@ \
		sw/runtime/sv39.S sw/memcpy/memcpy.S

$(MEMCPY_64K_VM_BIN): $(MEMCPY_64K_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_64K_VM_MEMH): $(MEMCPY_64K_VM_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(MEMCPY_VM_MEMH_BYTES) --word-bytes 32

$(MEMCPY_64K_VM_DISASM): $(MEMCPY_64K_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(MEMCPY_SWEEP_ELF): $(OPENRV64_MAKEFILES) sw/memcpy/memcpy_sweep.S \
		sw/runtime/bare.S sw/runtime/c_start.inc sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) -DOPENRV64_RUNTIME_NO_BSS_CLEAR \
		-Wl,--build-id=none,-Map,$(MEMCPY_SWEEP_MAP) \
		-T sw/openrv64.ld -o $@ sw/runtime/bare.S \
		sw/memcpy/memcpy_sweep.S

$(MEMCPY_SWEEP_BIN): $(MEMCPY_SWEEP_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_SWEEP_DISASM): $(MEMCPY_SWEEP_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(L1I_COREMARK_MEMH): $(COREMARK_LOOP_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x800 --word-bytes 64

$(VEC_MATMUL_ELF): $(OPENRV64_MAKEFILES) sw/vector/matmul.S sw/vector/matmul.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles -Wl,--build-id=none,-Map,$(VEC_MATMUL_MAP) \
		-T sw/vector/matmul.ld -o $@ sw/vector/matmul.S

$(VEC_MATMUL_BIN): $(VEC_MATMUL_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_DISASM): $(VEC_MATMUL_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_MEMH): $(VEC_MATMUL_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x700 --word-bytes 8

$(VEC_MATMUL_BF16_ELF): $(OPENRV64_MAKEFILES) sw/matmul_bf16.S sw/matmul_bf16.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map,$(VEC_MATMUL_BF16_MAP) \
		-T sw/matmul_bf16.ld -o $@ sw/matmul_bf16.S

$(VEC_MATMUL_BF16_BIN): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_BF16_DISASM): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_BF16_MEMH): $(VEC_MATMUL_BF16_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0xf00 --word-bytes 8

$(A53_COREMARK_ELF): $(OPENRV64_MAKEFILES) sw/arm_a53/coremark_loop_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_COREMARK_MAP) \
		-T sw/arm_a53/coremark_loop.ld -o $@ \
		sw/arm_a53/coremark_loop_start.S sw/coremark_loop.c

$(A53_COREMARK_BIN): $(A53_COREMARK_ELF)
	$(AARCH64_OBJCOPY) -O binary $< $@

$(A53_COREMARK_DISASM): $(A53_COREMARK_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(A53_GEM5_ELF): $(OPENRV64_MAKEFILES) sw/arm_a53/coremark_loop_se_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_GEM5_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/coremark_loop_se_start.S sw/coremark_loop.c

$(A53_GEM5_DISASM): $(A53_GEM5_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(AXI_3P_PERF_BIN): $(AXI_3P_PERF_ELF)
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O binary $< $@

$(AXI_3P_PERF_MEMH): $(AXI_3P_PERF_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $(AXI_3P_PERF_BIN) $@ \
		--size $(AXI_3P_PERF_MEMH_BYTES) --word-bytes 32

$(UART_FIRMWARE_MEMH): $(UART_FIRMWARE_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x10000
