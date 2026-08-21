# Software workloads and external reference-model runs.

sw-uart: $(UART_FIRMWARE_ELF) $(UART_FIRMWARE_BIN)

sw-fp-daxpy: $(FP_DAXPY_ELF) $(FP_DAXPY_BIN) $(FP_DAXPY_DISASM) \
	$(FP_DAXPY_MEMH)

sw-fp-daxpy-compute: $(FP_DAXPY_COMPUTE_ELF) \
	$(FP_DAXPY_COMPUTE_BIN) $(FP_DAXPY_COMPUTE_DISASM) \
	$(FP_DAXPY_COMPUTE_MEMH)

sw-fp-daxpy-store: $(FP_DAXPY_STORE_ELF) $(FP_DAXPY_STORE_BIN) \
	$(FP_DAXPY_STORE_DISASM) $(FP_DAXPY_STORE_MEMH)

sw-fp-fmadd32: $(FP_FMADD32_ELF) $(FP_FMADD32_BIN) \
	$(FP_FMADD32_DISASM) $(FP_FMADD32_MEMH)

sw-fp-faults: $(FP_FAULTS_ELF) $(FP_FAULTS_BIN) $(FP_FAULTS_DISASM) \
	$(FP_FAULTS_MEMH)

sw-smp-thread-probe: $(SMP_THREAD_PROBE_BIN) $(SMP_THREAD_TEST_SCRIPT) \
		$(LINUX_USER_STRESS_BIN) $(LINUX_USER_TEST_SCRIPT)

sw-linux-user-tests: $(LINUX_USER_STRESS_BIN) $(LINUX_USER_TEST_SCRIPT)

sw-linux-user-pthread-test: $(LINUX_USER_PTHREAD_BIN)

sw-coremark-loop: $(COREMARK_LOOP_ELF) $(COREMARK_LOOP_BIN)

sw-coremark: sw-coremark-bare

sw-coremark-bare: $(COREMARK_BARE_ELF) $(COREMARK_BARE_BIN) \
		$(COREMARK_BARE_MEMH) $(COREMARK_BARE_DISASM)

sw-coremark-bare-smoke: $(COREMARK_BARE_SMOKE_ELF) \
		$(COREMARK_BARE_SMOKE_BIN) $(COREMARK_BARE_SMOKE_MEMH) \
		$(COREMARK_BARE_SMOKE_DISASM)

sw-coremark-bare-run: $(COREMARK_BARE_RUN_ELF) \
		$(COREMARK_BARE_RUN_BIN) $(COREMARK_BARE_RUN_MEMH) \
		$(COREMARK_BARE_RUN_DISASM)

sw-coremark-loop-vm: $(CORE_3P_VM_ELF) $(CORE_3P_VM_BIN) \
		$(CORE_3P_VM_MEMH) $(CORE_3P_VM_DISASM)

sw-coremark-loop-4h-vm: $(CORE_4H_VM_ELF) $(CORE_4H_VM_TEMPLATE_BIN) \
		$(CORE_4H_VM_BIN) $(CORE_4H_VM_MEMH) $(CORE_4H_VM_DISASM)

sw-coremark-loop-4h-shared-vm: $(CORE_4H_SHARED_VM_ELF) \
		$(CORE_4H_SHARED_VM_TEMPLATE_BIN) $(CORE_4H_SHARED_VM_BIN) \
		$(CORE_4H_SHARED_VM_MEMH) $(CORE_4H_SHARED_VM_DISASM)

sw-coremark-loop-4h-bare: $(CORE_4H_BARE_ELF) $(CORE_4H_BARE_BIN) \
		$(CORE_4H_BARE_MEMH) $(CORE_4H_BARE_DISASM)

sw-coremark-loop-4h-bare-perf: $(CORE_4H_BARE_PERF_ELF) \
		$(CORE_4H_BARE_PERF_BIN) $(CORE_4H_BARE_PERF_MEMH) \
		$(CORE_4H_BARE_PERF_DISASM)

sw-coherence-shared-perf: $(COHERENCE_PERF_ARTIFACTS)

sw-coherence-1h-shared-perf: $(COHERENCE_1H_PERF_ARTIFACTS)

sw-coherence-4h-shared-perf: $(COHERENCE_4H_PERF_ARTIFACTS)

sw-coherent-atomic-latency-sv39: $(ATOMIC_LATENCY_ARTIFACTS)

sw-coherent-atomic-latency-4h-sv39: $(ATOMIC_LATENCY_4H_ARTIFACTS)

sw-atomic-4h-shared-vm: $(ATOMIC_4H_SHARED_VM_ELF) \
		$(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN) $(ATOMIC_4H_SHARED_VM_BIN) \
		$(ATOMIC_4H_SHARED_VM_MEMH) $(ATOMIC_4H_SHARED_VM_DISASM)

sw-ticket-lock-4h-shared-vm: $(TICKET_LOCK_4H_SHARED_VM_ELF) \
		$(TICKET_LOCK_4H_SHARED_VM_TEMPLATE_BIN) \
		$(TICKET_LOCK_4H_SHARED_VM_BIN) \
		$(TICKET_LOCK_4H_SHARED_VM_MEMH) \
		$(TICKET_LOCK_4H_SHARED_VM_DISASM)

sw-tlbi-4h-shared-vm: $(TLBI_4H_SHARED_VM_ELF) \
		$(TLBI_4H_SHARED_VM_TEMPLATE_BIN) $(TLBI_4H_SHARED_VM_BIN) \
		$(TLBI_4H_SHARED_VM_MEMH) $(TLBI_4H_SHARED_VM_DISASM)

sw-ipi-2h-shared-vm: $(IPI_2H_SHARED_VM_ELF) \
		$(IPI_2H_SHARED_VM_TEMPLATE_BIN) $(IPI_2H_SHARED_VM_BIN) \
		$(IPI_2H_SHARED_VM_MEMH) $(IPI_2H_SHARED_VM_DISASM)

sw-wfi-mailbox-4h-shared-vm: $(WFI_MAILBOX_4H_SHARED_VM_ELF) \
		$(WFI_MAILBOX_4H_SHARED_VM_TEMPLATE_BIN) \
		$(WFI_MAILBOX_4H_SHARED_VM_BIN) \
		$(WFI_MAILBOX_4H_SHARED_VM_MEMH) \
		$(WFI_MAILBOX_4H_SHARED_VM_DISASM)

sim-4h-3p-sv39: $(CORE_4H_3P_VERILATOR_BUILD) $(CORE_4H_VM_MEMH)
	test -n "$(CORE_4H_VM_DONE_PC)"
	test -n "$(CORE_4H_VM_MAILBOX_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_VM_MEMH)) \
		+memh_words=$(CORE_4H_VM_MEMH_WORDS) \
		+done_pc=$(CORE_4H_VM_DONE_PC) \
		+mailbox_va=$(CORE_4H_VM_MAILBOX_VA) \
		+max_cycles=$(CORE_4H_VM_MAX_CYCLES)

sim-4h-3p-shared-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(CORE_4H_SHARED_VM_MEMH)
	test -n "$(CORE_4H_SHARED_VM_DONE_PC)"
	test -n "$(CORE_4H_SHARED_VM_MAILBOX_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_SHARED_VM_MEMH)) \
		+memh_words=$(CORE_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(CORE_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(CORE_4H_SHARED_VM_MAILBOX_VA) \
		+shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(CORE_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-bare:
	$(MAKE) sim-4h-3p-bare-configured

sim-1h-coherent-3p-ddr3: sim-1h-coherent-3p-ddr3-private

sim-1h-coherent-3p-ddr3-private: \
		$(CORE_1H_COHERENT_3P_VERILATOR_BUILD) \
		$(call coherence_perf_memh_512,1,private)
	test -n "$(call coherence_perf_done_pc,1,private)"
	test -n "$(call coherence_perf_measure_start_pc,1,private)"
	test -n "$(call coherence_perf_measure_end_pc,1,private)"
	$(CORE_1H_COHERENT_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(call coherence_perf_memh_512,1,private)) \
		+memh_words=$(COHERENCE_PERF_512_WORDS) \
		+done_pc=$(call coherence_perf_done_pc,1,private) \
		+mailbox_va=$(call coherence_perf_results_va,1,private) \
		+result_va=$(call coherence_perf_status_va,1,private) \
		+result_expected=0 \
		+perf_results_va=$(call coherence_perf_results_va,1,private) \
		+perf_iterations=$(COHERENCE_PERF_ITERATIONS) \
		+perf_name=COHERENCE_1H_PRIVATE_DDR3 \
		+coherence_perf=1 +coherence_case=0 \
		+coherence_base_va=$(call coherence_perf_base_va,1,private) \
		+coherence_lines=1 +coherence_line_stride=4096 \
		+coherence_operations=$(COHERENCE_PERF_ITERATIONS) \
		+coherence_measure_start_pc=$(call coherence_perf_measure_start_pc,1,private) \
		+coherence_measure_end_pc=$(call coherence_perf_measure_end_pc,1,private) \
		+active_harts=1 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(COHERENCE_PERF_MAX_CYCLES)

define COHERENT_ATOMIC_LATENCY_RUN
sim-coherent-atomic-latency-sv39-$1: \
		$(CORE_1H_COHERENT_3P_VERILATOR_BUILD) \
		$(call coherence_perf_memh_512,1,$1)
	test -n "$$(call coherence_perf_done_pc,1,$1)"
	test -n "$$(call coherence_perf_measure_start_pc,1,$1)"
	test -n "$$(call coherence_perf_measure_end_pc,1,$1)"
	$(CORE_1H_COHERENT_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(call coherence_perf_memh_512,1,$1)) \
		+memh_words=$(COHERENCE_PERF_512_WORDS) \
		+done_pc=$$(call coherence_perf_done_pc,1,$1) \
		+mailbox_va=$$(call coherence_perf_results_va,1,$1) \
		+result_va=$$(call coherence_perf_status_va,1,$1) \
		+result_expected=0 \
		+perf_results_va=$$(call coherence_perf_results_va,1,$1) \
		+perf_iterations=$(COHERENCE_PERF_ITERATIONS) \
		+perf_name=ATOMIC_LATENCY_$1 \
		+coherence_perf=1 \
		+coherence_case=$(call coherence_perf_case_id,$1) \
		+coherence_base_va=$$(call coherence_perf_base_va,1,$1) \
		+coherence_lines=1 +coherence_line_stride=64 \
		+coherence_operations=$(COHERENCE_PERF_ITERATIONS) \
		+coherence_measure_start_pc=$$(call coherence_perf_measure_start_pc,1,$1) \
		+coherence_measure_end_pc=$$(call coherence_perf_measure_end_pc,1,$1) \
		+debug_counter_start_pc=$$(call coherence_perf_measure_start_pc,1,$1) \
		+debug_counter_stop_pc=$$(call coherence_perf_measure_end_pc,1,$1) \
		+active_harts=1 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(COHERENCE_PERF_MAX_CYCLES)
endef

$(foreach case,$(ATOMIC_LATENCY_CASES),\
	$(eval $(call COHERENT_ATOMIC_LATENCY_RUN,$(case))))

build-coherent-atomic-latency-sv39: \
		$(CORE_1H_COHERENT_3P_VERILATOR_BUILD) \
		$(ATOMIC_LATENCY_ARTIFACTS)

bench-coherent-atomic-latency-sv39: $(foreach case,\
		$(ATOMIC_LATENCY_CASES),\
		sim-coherent-atomic-latency-sv39-$(case))
	@echo "PASS coherent atomic latency Sv39 matrix"

define COHERENT_ATOMIC_LATENCY_4H_RUN
sim-coherent-atomic-latency-4h-sv39-$1: \
		$(CORE_4H_3P_VERILATOR_BUILD) \
		$(call coherence_perf_memh_512,4,$1)
	test -n "$$(call coherence_perf_done_pc,4,$1)"
	test -n "$$(call coherence_perf_measure_start_pc,4,$1)"
	test -n "$$(call coherence_perf_measure_end_pc,4,$1)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(call coherence_perf_memh_512,4,$1)) \
		+memh_words=$(COHERENCE_PERF_512_WORDS) \
		+done_pc=$$(call coherence_perf_done_pc,4,$1) \
		+mailbox_va=$$(call coherence_perf_results_va,4,$1) \
		+result_va=$$(call coherence_perf_status_va,4,$1) \
		+result_expected=0 \
		+perf_results_va=$$(call coherence_perf_results_va,4,$1) \
		+perf_iterations=$(COHERENCE_PERF_ITERATIONS) \
		+perf_name=ATOMIC_LATENCY_4H_$1 \
		+coherence_perf=1 \
		+coherence_case=$(call coherence_perf_case_id,$1) \
		+coherence_base_va=$$(call coherence_perf_base_va,4,$1) \
		+coherence_lines=$(call coherence_perf_case_lines,4,$1) \
		+coherence_line_stride=64 \
		+coherence_operations=$(call coherence_perf_operations,4,$1) \
		+coherence_measure_start_pc=$$(call coherence_perf_measure_start_pc,4,$1) \
		+coherence_measure_end_pc=$$(call coherence_perf_measure_end_pc,4,$1) \
		+debug_counter_start_pc=$$(call coherence_perf_measure_start_pc,4,$1) \
		+debug_counter_stop_pc=$$(call coherence_perf_measure_end_pc,4,$1) \
		+active_harts=4 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(COHERENCE_PERF_MAX_CYCLES)
endef

$(foreach case,$(ATOMIC_LATENCY_4H_CASES),\
	$(eval $(call COHERENT_ATOMIC_LATENCY_4H_RUN,$(case))))

build-coherent-atomic-latency-4h-sv39: \
		$(CORE_4H_3P_VERILATOR_BUILD) \
		$(ATOMIC_LATENCY_4H_ARTIFACTS)

bench-coherent-atomic-latency-4h-sv39: $(foreach case,\
		$(ATOMIC_LATENCY_4H_CASES),\
		sim-coherent-atomic-latency-4h-sv39-$(case))
	@echo "PASS coherent atomic latency four-active-hart Sv39 matrix"

.PHONY: sw-coherent-atomic-latency-sv39 \
	build-coherent-atomic-latency-sv39 \
	bench-coherent-atomic-latency-sv39 \
	sw-coherent-atomic-latency-4h-sv39 \
	build-coherent-atomic-latency-4h-sv39 \
	bench-coherent-atomic-latency-4h-sv39

sim-4h-3p-bare-configured: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(CORE_4H_BARE_MEMH)
	test -n "$(CORE_4H_BARE_DONE_PC)"
	test -n "$(CORE_4H_BARE_MAILBOX_PA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_BARE_MEMH)) \
		+memh_words=$(CORE_4H_BARE_MEMH_WORDS) \
		+done_pc=$(CORE_4H_BARE_DONE_PC) \
		+mailbox_va=$(CORE_4H_BARE_MAILBOX_PA) \
		+bare=1 +mailbox_stride=4096 \
		+max_cycles=$(CORE_4H_BARE_MAX_CYCLES)

sim-4h-3p-bare-perf: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(CORE_4H_BARE_PERF_MEMH)
	test -n "$(CORE_4H_BARE_PERF_DONE_PC)"
	test -n "$(CORE_4H_BARE_PERF_RESULTS_PA)"
	test -n "$(CORE_4H_BARE_PERF_STATUS_PA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_BARE_PERF_MEMH)) \
		+memh_words=$(CORE_4H_BARE_PERF_MEMH_WORDS) \
		+done_pc=$(CORE_4H_BARE_PERF_DONE_PC) \
		+mailbox_va=$(CORE_4H_BARE_PERF_RESULTS_PA) \
		+result_va=$(CORE_4H_BARE_PERF_STATUS_PA) \
		+result_expected=0 \
		+perf_results_va=$(CORE_4H_BARE_PERF_RESULTS_PA) \
		+perf_iterations=$(CORE_4H_BARE_PERF_ITERATIONS) \
		+bare=1 +mailbox_stride=4096 \
		+max_cycles=$(CORE_4H_BARE_PERF_MAX_CYCLES)

define COHERENCE_4H_PERF_RUN
sim-4h-3p-coherence-$1h-$2: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(call coherence_perf_memh_512,$1,$2)
	test -n "$$(call coherence_perf_done_pc,$1,$2)"
	test -n "$$(call coherence_perf_measure_start_pc,$1,$2)"
	test -n "$$(call coherence_perf_measure_end_pc,$1,$2)"
	test -n "$$(call coherence_perf_results_va,$1,$2)"
	test -n "$$(call coherence_perf_status_va,$1,$2)"
	test -n "$$(call coherence_perf_base_va,$1,$2)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(call coherence_perf_memh_512,$1,$2)) \
		+memh_words=$(COHERENCE_PERF_512_WORDS) \
		+done_pc=$$(call coherence_perf_done_pc,$1,$2) \
		+mailbox_va=$$(call coherence_perf_results_va,$1,$2) \
		+result_va=$$(call coherence_perf_status_va,$1,$2) \
		+result_expected=0 \
		+perf_results_va=$$(call coherence_perf_results_va,$1,$2) \
		+perf_iterations=$(COHERENCE_PERF_ITERATIONS) \
		+perf_name=COHERENCE_$1H_$2 \
		+coherence_perf=1 \
		+coherence_case=$(call coherence_perf_case_id,$2) \
		+coherence_base_va=$$(call coherence_perf_base_va,$1,$2) \
		+coherence_lines=$(call coherence_perf_case_lines,$1,$2) \
		+coherence_line_stride=$(call coherence_perf_line_stride,$2) \
		+coherence_operations=$(call coherence_perf_operations,$1,$2) \
		+coherence_measure_start_pc=$$(call coherence_perf_measure_start_pc,$1,$2) \
		+coherence_measure_end_pc=$$(call coherence_perf_measure_end_pc,$1,$2) \
		+active_harts=$1 \
		+shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(COHERENCE_PERF_MAX_CYCLES)
endef

$(foreach harts,$(COHERENCE_PERF_HART_COUNTS),\
	$(foreach case,$(COHERENCE_PERF_CASES),\
		$(eval $(call COHERENCE_4H_PERF_RUN,$(harts),$(case)))))

define COHERENCE_1H_PERF_RUN
sim-1h-3p-coherence-$1: $(call coherence_perf_memh_256,1,$1)
	$$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=0 \
		CORE_3P_ICX_L2_MEMH=$(call coherence_perf_memh_256,1,$1) \
		CORE_3P_ICX_L2_MEMH_WORDS=$$(COHERENCE_PERF_256_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$$(COHERENCE_PERF_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$$(call coherence_perf_done_pc,1,$1) +expect_a0=$(call coherence_perf_signature,$1) +require_sv39 +report_coherence_1h"
endef

$(foreach case,$(COHERENCE_PERF_CASES),\
	$(eval $(call COHERENCE_1H_PERF_RUN,$(case))))

sim-4h-3p-coherence-suite: $(foreach case,$(COHERENCE_PERF_CASES),\
	sim-4h-3p-coherence-4h-$(case))

sim-1h-3p-coherence-suite: $(foreach case,$(COHERENCE_PERF_CASES),\
	sim-1h-3p-coherence-$(case))

sim-4h-3p-coherence-scaling-suite: $(foreach harts,\
	$(COHERENCE_PERF_HART_COUNTS),$(foreach case,$(COHERENCE_PERF_CASES),\
	sim-4h-3p-coherence-$(harts)h-$(case)))

sim-coherence-scaling-suite: sim-1h-3p-coherence-suite \
		sim-4h-3p-coherence-scaling-suite

sim-4h-3p-coherence-private: sim-4h-3p-coherence-4h-private
sim-4h-3p-coherence-handoff1: sim-4h-3p-coherence-4h-same_line
sim-4h-3p-coherence-handoff8: sim-4h-3p-coherence-4h-same_page
sim-4h-3p-coherence-lrsc1: sim-4h-3p-coherence-4h-lrsc

sim-4h-3p-atomic-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(ATOMIC_4H_SHARED_VM_MEMH)
	test -n "$(ATOMIC_4H_SHARED_VM_DONE_PC)"
	test -n "$(ATOMIC_4H_SHARED_VM_MAILBOX_VA)"
	test -n "$(ATOMIC_4H_SHARED_VM_SUCCESS_VA)"
	test -n "$(ATOMIC_4H_SHARED_VM_COUNTER_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(ATOMIC_4H_SHARED_VM_MEMH)) \
		+memh_words=$(ATOMIC_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(ATOMIC_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(ATOMIC_4H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(ATOMIC_4H_SHARED_VM_SUCCESS_VA) \
		+result_expected=$(ATOMIC_4H_SHARED_VM_SUCCESSES) \
		+atomic_counter_va=$(ATOMIC_4H_SHARED_VM_COUNTER_VA) \
		+atomic_expected=$(ATOMIC_4H_SHARED_VM_FINAL_VALUE) \
		+shared_satp=1 +mailbox_stride=4096 +atomic_test=1 \
		+max_cycles=$(ATOMIC_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-tlbi-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(TLBI_4H_SHARED_VM_MEMH)
	test -n "$(TLBI_4H_SHARED_VM_DONE_PC)"
	test -n "$(TLBI_4H_SHARED_VM_MAILBOX_VA)"
	test -n "$(TLBI_4H_SHARED_VM_RESULT_VA)"
	test -n "$(TLBI_4H_SHARED_VM_RESERVATION_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(TLBI_4H_SHARED_VM_MEMH)) \
		+memh_words=$(TLBI_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(TLBI_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(TLBI_4H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(TLBI_4H_SHARED_VM_RESULT_VA) \
		+result_expected=1 \
		+tlbi_reservation_va=$(TLBI_4H_SHARED_VM_RESERVATION_VA) \
		+tlbi_target_va=$(TLBI_4H_SHARED_VM_TARGET_VA) \
		+tlbi_old_pa=$(TLBI_4H_SHARED_VM_OLD_PA) \
		+tlbi_new_pa=$(TLBI_4H_SHARED_VM_NEW_PA) \
		+shared_satp=1 +mailbox_stride=4096 +tlbi_test=1 \
		+max_cycles=$(TLBI_4H_SHARED_VM_MAX_CYCLES)

sim-2h-3p-ipi-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(IPI_2H_SHARED_VM_MEMH)
	test -n "$(IPI_2H_SHARED_VM_DONE_PC)"
	test -n "$(IPI_2H_SHARED_VM_MAILBOX_VA)"
	test -n "$(IPI_2H_SHARED_VM_RESULT_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(IPI_2H_SHARED_VM_MEMH)) \
		+memh_words=$(IPI_2H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(IPI_2H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(IPI_2H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(IPI_2H_SHARED_VM_RESULT_VA) \
		+result_expected=$(IPI_2H_SHARED_VM_ROUNDS) \
		+ipi_test=1 +ipi_expected=$(IPI_2H_SHARED_VM_ROUNDS) \
		+active_harts=2 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(IPI_2H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-ticket-lock-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(TICKET_LOCK_4H_SHARED_VM_MEMH)
	test -n "$(TICKET_LOCK_4H_SHARED_VM_DONE_PC)"
	test -n "$(TICKET_LOCK_4H_SHARED_VM_MAILBOX_VA)"
	test -n "$(TICKET_LOCK_4H_SHARED_VM_RESULT_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(TICKET_LOCK_4H_SHARED_VM_MEMH)) \
		+memh_words=$(TICKET_LOCK_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(TICKET_LOCK_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(TICKET_LOCK_4H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(TICKET_LOCK_4H_SHARED_VM_RESULT_VA) \
		+result_expected=0 \
		+active_harts=4 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(TICKET_LOCK_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-wfi-mailbox-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(WFI_MAILBOX_4H_SHARED_VM_MEMH)
	test -n "$(WFI_MAILBOX_4H_SHARED_VM_DONE_PC)"
	test -n "$(WFI_MAILBOX_4H_SHARED_VM_MAILBOX_VA)"
	test -n "$(WFI_MAILBOX_4H_SHARED_VM_RESULT_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(WFI_MAILBOX_4H_SHARED_VM_MEMH)) \
		+memh_words=$(WFI_MAILBOX_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(WFI_MAILBOX_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(WFI_MAILBOX_4H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(WFI_MAILBOX_4H_SHARED_VM_RESULT_VA) \
		+result_expected=$(WFI_MAILBOX_4H_SHARED_VM_ROUNDS) \
		+ipi_test=2 +ipi_expected=$(WFI_MAILBOX_4H_SHARED_VM_ROUNDS) \
		+active_harts=4 +shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(WFI_MAILBOX_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-shared-suite: sim-4h-3p-shared-sv39 \
		sim-4h-3p-atomic-sv39 sim-4h-3p-tlbi-sv39 \
		sim-2h-3p-ipi-sv39 sim-4h-3p-wfi-mailbox-sv39

sw-zero-sv39: $(ZERO_VM_ELF) $(ZERO_VM_BIN) $(ZERO_VM_MEMH) \
		$(ZERO_VM_DISASM)

sw-atomic: $(ATOMIC_SOC_ELF) $(ATOMIC_SOC_BIN) $(ATOMIC_SOC_DISASM)

sim-core-3p-magic: $(CORE_3P_MAGIC_VERILATOR_BUILD) \
		$(CORE_3P_MAGIC_MEMH)
	$(CORE_3P_MAGIC_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_3P_MAGIC_MEMH)) \
		+max_cycles=$(CORE_3P_MAGIC_MAX_CYCLES) \
		+expect_a0=$(CORE_3P_MAGIC_EXPECT_A0)

sim-core-3p-magic-sweep:
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=0
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=1
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=2

sim-core-3p-icx-l2: $(CORE_3P_ICX_L2_VERILATOR_BUILD) \
		$(CORE_3P_ICX_L2_MEMH)
	$(CORE_3P_ICX_L2_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_3P_ICX_L2_MEMH)) \
		+memh_words=$(CORE_3P_ICX_L2_MEMH_WORDS) \
		+max_cycles=$(CORE_3P_ICX_L2_MAX_CYCLES) \
		$(CORE_3P_ICX_L2_ARGS)

sim-core-3p-icx-l2-vm: $(CORE_3P_VM_MEMH)
	test -n "$(CORE_3P_VM_DONE_PC)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_ICX_L2_MEMH=$(CORE_3P_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(CORE_3P_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(CORE_3P_VM_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(CORE_3P_ICX_L2_EXPECT_A0) +done_pc=$(CORE_3P_VM_DONE_PC) +require_sv39"

bench-zero-sv39: $(ZERO_VM_MEMH)
	test -n "$(ZERO_VM_MEASURE_END)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_CONFIDENCE_GATE=1 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_ICX_L2_MEMH=$(ZERO_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(ZERO_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(ZERO_VM_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+done_pc=$(ZERO_VM_MEASURE_END) +require_zero_scatter"

sim-zero-sv39: $(ZERO_VM_MEMH)
	test -n "$(ZERO_VM_DONE)"
	$(MAKE) sim-core-3p-icx-l2 \
		CORE_3P_ICX_L2_MODE=3 \
		CORE_3P_ICX_L2_CONFIDENCE_GATE=1 \
		CORE_3P_ICX_L2_RETIRE_DEPTH=16 \
		CORE_3P_ICX_L2_ISSUE_WINDOW=1 \
		CORE_3P_ICX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_ICX_L2_POSTED_STORES=1 \
		CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_ICX_L2_DDR3=1 \
		CORE_3P_ICX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_ICX_L2_MEMH=$(ZERO_VM_MEMH) \
		CORE_3P_ICX_L2_MEMH_WORDS=$(ZERO_VM_MEMH_WORDS) \
		CORE_3P_ICX_L2_MAX_CYCLES=$(ZERO_VM_MAX_CYCLES) \
		CORE_3P_ICX_L2_ARGS="+expect_a0=$(ZERO_VM_PASS) +done_pc=$(ZERO_VM_DONE) +require_zero_scatter"

sim-atomic-soc: $(CORE_3P_ICX_L2_VERILATOR_BUILD) $(ATOMIC_SOC_MEMH)
	$(CORE_3P_ICX_L2_VERILATOR_BUILD) \
		+memh=$(abspath $(ATOMIC_SOC_MEMH)) \
		+memh_words=$(ATOMIC_SOC_MEMH_WORDS) \
		+max_cycles=$(ATOMIC_SOC_MAX_CYCLES) \
		+expect_a0=$(ATOMIC_SOC_PASS)

sw-memcpy: sw-memcpy-4k sw-memcpy-64k sw-memcpy-sweep

sw-memcpy-4k: $(MEMCPY_4K_ELF) $(MEMCPY_4K_BIN) \
	$(MEMCPY_4K_DISASM)

sw-memcpy-64k: $(MEMCPY_64K_ELF) $(MEMCPY_64K_BIN) \
	$(MEMCPY_64K_DISASM)

sw-memcpy-sweep: $(MEMCPY_SWEEP_ELF) $(MEMCPY_SWEEP_BIN) \
	$(MEMCPY_SWEEP_DISASM)

sim-memcpy: sim-memcpy-4k sim-memcpy-64k sim-memcpy-sweep

sim-memcpy-4k: $(MEMCPY_4K_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_4K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-4k-check.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-4k-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_4K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +expect_a0=$(MEMCPY_PASS)" \
		AXI_3P_TRACE_CSV=sim/memcpy-4k-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-4k-check-pipeline.txt

sim-memcpy-64k: $(MEMCPY_64K_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_64K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-64k-check.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-64k-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_64K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +expect_a0=$(MEMCPY_PASS)" \
		AXI_3P_TRACE_CSV=sim/memcpy-64k-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-64k-check-pipeline.txt

sim-memcpy-sweep: bench-memcpy-sweep

bench-memcpy: bench-memcpy-4k bench-memcpy-64k bench-memcpy-sweep

bench-memcpy-4k: $(MEMCPY_4K_ELF)
	test -n "$(MEMCPY_4K_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_4K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-4k-bench.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-4k-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_4K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +done_pc=$(MEMCPY_4K_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/memcpy-4k-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-4k-bench-pipeline.txt

bench-memcpy-64k: $(MEMCPY_64K_ELF)
	test -n "$(MEMCPY_64K_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_64K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-64k-bench.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-64k-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_64K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +done_pc=$(MEMCPY_64K_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/memcpy-64k-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-64k-bench-pipeline.txt

bench-memcpy-sweep: $(MEMCPY_SWEEP_ELF)
	test -n "$(MEMCPY_SWEEP_REPORT_PC)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_SWEEP_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-sweep.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-sweep.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_SWEEP_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_SWEEP_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_SWEEP_MEMH_WORDS) +expect_a0=$(MEMCPY_PASS) +memcpy_report_pc=$(MEMCPY_SWEEP_REPORT_PC) +memcpy_report_expected=$(MEMCPY_SWEEP_REPORTS)" \
		AXI_3P_TRACE_CSV=sim/memcpy-sweep-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-sweep-pipeline.txt

sw-vector-matmul: $(VEC_MATMUL_ELF) $(VEC_MATMUL_BIN) \
		$(VEC_MATMUL_DISASM)

sw-matmul-bf16: $(VEC_MATMUL_BF16_ELF) $(VEC_MATMUL_BF16_BIN) \
		$(VEC_MATMUL_BF16_DISASM)

sw-coremark-loop-a53: $(A53_COREMARK_ELF) $(A53_COREMARK_BIN) \
		$(A53_COREMARK_DISASM)

sw-coremark-loop-a53-gem5: $(A53_GEM5_ELF) $(A53_GEM5_DISASM)

sim-coremark-loop-a53-qemu: sw-coremark-loop-a53
	mkdir -p $(dir $(A53_QEMU_TRACE)) $(dir $(A53_QEMU_REPORT))
	$(QEMU_AARCH64) -M virt,secure=off,virtualization=off \
		-accel tcg,one-insn-per-tb=on -cpu cortex-a53 -smp 1 \
		-m 128M -display none -serial none -monitor none \
		-semihosting-config enable=on,target=native \
		-device loader,file=$(abspath $(A53_COREMARK_ELF)),cpu-num=0 \
		-d in_asm,exec,nochain -D $(A53_QEMU_TRACE)
	$(PYTHON) tools/qemu_one_insn_trace.py $(A53_QEMU_TRACE) \
		--output $(A53_QEMU_REPORT)
	@cat $(A53_QEMU_REPORT)

sim-coremark-loop-a53-gem5: sw-coremark-loop-a53-gem5
	test -x $(GEM5_AARCH64)
	test -f $(GEM5_A53_CONFIG)
# gem5 25.1 HPI underflows its activity recorder on the initial idle edge
# here. Ticked still accounts stopped cycles, so keeping the pipeline clocked
# avoids the bug without removing wait cycles.
	$(GEM5_AARCH64) -d $(A53_GEM5_OUTDIR) \
		--debug-flags=$(A53_GEM5_DEBUG_FLAGS) \
		--debug-file=$(notdir $(A53_GEM5_TRACE)) \
		$(GEM5_A53_CONFIG) --cpu=hpi --cpu-freq=1GHz \
		--num-cores=1 --mem-type=DDR3_1600_8x8 --mem-channels=1 \
		--mem-size=128MiB \
		-P 'system.cpu_cluster.cpus[0].enableIdling=False' \
		$(abspath $(A53_GEM5_ELF))
	$(PYTHON) tools/gem5_hpi_report.py $(A53_GEM5_STATS) \
		--trace $(A53_GEM5_TRACE) --output $(A53_GEM5_REPORT)
