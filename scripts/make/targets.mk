# Aggregate targets and phony declarations.

.PHONY: FORCE fpga-sd-image verify-fpga-sd-image fpga-opensbi-core-dcp \
	fpga-xc7k480t-3p-yosys fpga-xc7k480t-3p-yosys-check \
	fpga-xc7k480t-3p-vivado fpga-xc7k480t-3p-vivado-check \
	fpga-xc7k480t-dispatch-rename-breakdown \
	fpga-xc7k480t-dispatch-rename-breakdown-check \
	fpga-xc7k480t-module-stats fpga-xc7k480t-module-stats-check \
	fpga-xc7k480t-3p-utilization \
	fpga-xc7k480t-3p-utilization-check \
	opensbi-fpga-linux-debug verify-opensbi-fpga-linux-debug \
	fpga-debug-snapshot-synth verify-fpga-debug-snapshot-synth \
	fpga-debug-stub-synth verify-fpga-debug-stub-synth \
	fpga-debug-uart-trace-synth verify-fpga-debug-uart-trace-synth \
	fpga-sd-boot-rom \
	fpga-sd-boot-bitstream fpga-sd-boot-bitstream-check \
	fpga-program-bitstream \
	fpga-jtag-snoop \
	fpga-debug-dtb-probe \
	fpga-debug-dtb-probe-read \
	fpga-debug-strcmp-probe \
	fpga-debug-strcmp-probe-read \
	fpga-debug-memblock-probe \
	fpga-debug-memblock-probe-read \
	fpga-sd-boot-core-timing-report \
	fpga-sd-boot-core-timing-report-check \
	sim-fpga-sd-boot sim-fpga-jtag-snoop sim-fpga-debug-stub \
	sim-fpga-debug-uart-trace \
	sim-fpga-debug-exec sim-ethernet \
	sw-uart sw-fp-daxpy sw-fp-daxpy-compute \
	sw-fp-daxpy-store \
	sw-fp-fmadd32 sw-fp-faults \
	sw-smp-thread-probe sw-linux-user-tests sw-linux-user-pthread-test \
	sw-coremark sw-coremark-bare sw-coremark-bare-smoke \
	sw-coremark-bare-run sw-coremark-loop \
	sw-coremark-loop-vm \
	sw-coremark-loop-4h-vm sim-4h-3p-sv39 \
	sw-coremark-loop-4h-shared-vm sw-atomic-4h-shared-vm \
	sw-ticket-lock-4h-shared-vm \
	sw-tlbi-4h-shared-vm sw-ipi-2h-shared-vm \
	sw-wfi-mailbox-4h-shared-vm \
	sw-coremark-loop-4h-bare sim-4h-3p-bare \
	sim-4h-3p-bare-configured \
	sim-1h-coherent-3p-ddr3 sim-1h-coherent-3p-ddr3-private \
	sw-coremark-loop-4h-bare-perf sim-4h-3p-bare-perf \
	sw-coherence-shared-perf sw-coherence-1h-shared-perf \
	sw-coherence-4h-shared-perf \
	sim-4h-3p-coherence-private \
	sim-4h-3p-coherence-handoff1 \
	sim-4h-3p-coherence-handoff8 \
	sim-4h-3p-coherence-lrsc1 \
	sim-1h-3p-coherence-suite sim-4h-3p-coherence-suite \
	sim-4h-3p-coherence-scaling-suite sim-coherence-scaling-suite \
	sim-4h-3p-shared-sv39 sim-4h-3p-atomic-sv39 \
	sim-4h-3p-ticket-lock-sv39 \
	sim-4h-3p-tlbi-sv39 sim-2h-3p-ipi-sv39 \
	sim-4h-3p-wfi-mailbox-sv39 \
	sim-4h-3p-shared-suite \
	sw-zero-sv39 bench-zero-sv39 sim-zero-sv39 sw-atomic \
	sim-atomic-soc \
	sw-memcpy sw-memcpy-4k sw-memcpy-64k sw-memcpy-sweep \
	sim-memcpy sim-memcpy-4k sim-memcpy-64k sim-memcpy-sweep \
	bench-memcpy bench-memcpy-4k bench-memcpy-64k bench-memcpy-sweep \
	sw-coremark-loop-a53 sw-coremark-loop-a53-gem5 sw-vector-matmul sw-matmul-bf16 sim-coremark-loop-a53-qemu sim-coremark-loop-a53-gem5 opensbi sim-opensbi sim-opensbi-icarus sim sim-top sim-platform sim-reset-sequencer sim-uart-firmware sim-uart-firmware-perf sim-top-trace sim-sw-trace trace-report sim-clint sim-plic sim-uart sim-gpio sim-timer sim-spi sim-rom sim-memory sim-soc-bus sim-core-bus sim-icx-bus sim-tlb sim-micro-tlb sim-tlb-l2 sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-banked sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-window-3p sim-dispatch-load-conflict sim-dispatch-3p sim-dispatch-3p-banked sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-pipe-mem-timeout sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-recursive-lock-context sim-wfi-context sim-exec-br sim-exec-bp sim-bp-context sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last sim-bp-context-btfnt sim-bp-context-bimodal sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p sim-top-axi-3p-bp sim-top-axi-3p-perf sky130-liberty yosys-timing-alu yosys-timing-alu-rv64i yosys-timing-alu-rv64m yosys-timing-alu-rv64i-sky130 yosys-timing-frontend yosys-timing-frontend-sky130 clean
.PHONY: sim-isa-fp sim-rv64-fd-fpr sim-fpu-csrs sim-exec-ext-zbb \
	sim-exec-fpu-rv64-fd sim-exec-fpu-rv64-fd-compact-mul \
	sim-fd-dispatch sim-fd-uop-harness sim-fd-uop-harness-compact-mul \
	sim-top-4pf sim-top-4pf-daxpy-compute sim-top-4pf-daxpy-store \
	sim-top-4pf-fmadd32 \
	sim-top-4pf-faults
.PHONY: sim-decode-rv64c sim-decode-rv64-fd
.PHONY: sim-decode-fusion
.PHONY: sim-exec-alu-rv64-m-fpga
.PHONY: sim-lsq-committed-store
.PHONY: sim-regfile sim-retire-3p-banked sim-backend-3p-banked \
	sim-backend-3p-banked-tomasulo sim-backend-3p-banked-window
.PHONY: sim-top-3p-banked
.PHONY: sim-vec sim-rv64-i-vec sim-exec-vec sim-exec-vec-lsu \
	sim-vec-cache sim-vec-cache-axi sim-vec-cache-wb \
	sim-vec-cache-wb-512 sim-vec-test-top \
	sim-vec-matmul sim-vec-matmul-bf16
.PHONY: $(foreach case,$(COHERENCE_PERF_CASES),\
	sim-1h-3p-coherence-$(case)) \
	$(foreach harts,$(COHERENCE_PERF_HART_COUNTS),\
	$(foreach case,$(COHERENCE_PERF_CASES),\
	sim-4h-3p-coherence-$(harts)h-$(case)))
.PHONY: sim-bp-context-gshare-btb sim-bp-context-gshare-btb-512 \
	sim-bp-context-tournament-btb sim-bp-context-tage-btb \
	sim-bp-context-tage-btb-nopredecode sim-bp-context-fpga-queue \
	sim-exec-bp-basic sim-exec-bp-tage
.PHONY: yosys-resources-core-sky130
.PHONY: nangate45-liberty yosys-timing-alu-rv64i-nangate45 \
	yosys-timing-frontend-nangate45 \
	yosys-resources-core-4pf-fd-nangate45 \
	yosys-resources-core-4pf-nofd-nangate45 \
	yosys-resources-core-4pf-nangate45
.PHONY: opensbi-4h-held sim-opensbi-4h-held \
	sim-linux-4h-held sim-linux-4h-held-configured \
	opensbi-4h-smp sim-opensbi-4h-smp \
	opensbi-1h-linux-coherent opensbi-2h-linux-smp opensbi-4h-linux-smp \
	sim-linux-2h-smp sim-linux-2h-smp-configured \
	sim-linux-4h-smp sim-linux-4h-smp-configured \
	opensbi-2h-hart-start opensbi-4h-hart-start \
	sim-opensbi-2h-hart-start \
	sim-opensbi-2h-hart-start-configured \
	sim-opensbi-4h-hart-start \
	sim-opensbi-4h-hart-start-configured \
	sim-opensbi-hart-start \
	sim-opensbi-3p sim-opensbi-3p-platform \
	sim-linux-3p-platform-checkpoint sim-linux-3p-platform-restore
.PHONY: sim-linux
.PHONY: sim-l1-cache sim-l1-sync-tag sim-l1-tag-mode-performance \
	sim-lsq-l1d-store-performance \
	sim-l1d-prefetch \
	sim-l1d-demand-mshr \
	sim-l1d-retired-store-mshr \
	sim-l1d-store-order \
	sim-l1d-store-buffer sim-l1d-fence-behavior \
	sim-l1d-invalidate-arbiter \
	sim-l1i-top sim-l1i-fill-owner sim-icx-protocol-1h \
	sim-icx-protocol-2h sim-icx-protocol-4h \
	sim-icx-coherent-2h sim-icx-coherent-4h \
	sim-icx-coherent-protocol-2h sim-icx-coherent-protocol-4h \
	sim-icx-4h-l1d-directory-l2
.PHONY: sim-core-3p-magic sim-core-3p-magic-sweep sim-core-3p-icx-l2 \
	sim-core-3p-icx-l2-vm generate-core-3p-branch-oracle \
	compress-core-3p-pipeline-state-trace \
	check-core-3p-pipeline-state-trace \
	sim-store-extension-sv39 \
	sim-store-extension-sv39-suite
.PHONY: sim-icx-l2 sim-icx-l2-sc-refill
.PHONY: sim-genbus-axi sim-genbus-wb sim-genbus-wb-widths
.PHONY: sim-core-complex-1h-axi sim-core-complex-2h-axi \
	sim-core-complex-4h-wb
.PHONY: sim-mem-channel sim-l2-axi-ddr3 sim-mesh-router
.PHONY: sim-prf sim-rename-identity sim-rename-tomasulo sim-lsq sim-lsu-atomics \
	sim-lsu-misaligned \
	sim-zicclsm-context \
	sim-exec-top-3p-no-zicclsm
.PHONY: sim-mtl-pmp
.PHONY: compliance-doctor compliance-smoke-local compliance-smoke-local-1p \
	compliance-smoke-local-3p compliance-smoke-local-platform \
	compliance-smoke-local-platform-3p \
	compliance-trace-contract compliance-quick compliance-full \
	compliance-act4-trace-3p-ab compliance-act4-3p \
	compliance-act4-3p-banked compliance-act4-platform-3p-ddr3 \
	compliance-act4-platform-3p-banked-ddr3

FORCE:

sim: sim-top sim-reset-sequencer sim-platform sim-uart-firmware sim-clint sim-plic sim-uart sim-gpio sim-timer sim-spi sim-ethernet sim-rom sim-memory sim-soc-bus sim-core-bus sim-icx-bus sim-tlb sim-micro-tlb sim-tlb-l2 sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-banked sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-3p sim-dispatch-3p-banked sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-top-3p-no-zicclsm sim-exec-pipe-mem-timeout sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-wfi-context sim-exec-br sim-exec-bp sim-bp-context sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p
sim: sim-isa-fp sim-rv64-fd-fpr sim-fpu-csrs sim-exec-fpu-rv64-fd
sim: sim-exec-alu-rv64-m-fpga
sim: sim-backend-3p-banked
sim: sim-top-3p-banked
sim: sim-decode-rv64c sim-decode-rv64-fd
sim: sim-fd-dispatch
sim: sim-fd-uop-harness
sim: sim-atomic-soc
sim: sim-vec
sim: sim-prf
sim: sim-rename-identity
sim: sim-rename-tomasulo
sim: sim-lsq
sim: sim-lsu-atomics
sim: sim-lsu-misaligned
sim: sim-zicclsm-context
sim: sim-mtl-pmp
sim: sim-l1-cache
sim: sim-l1-sync-tag
sim: sim-l1-tag-mode-performance
sim: sim-lsq-l1d-store-performance
sim: sim-l1d-prefetch
sim: sim-l1d-demand-mshr
sim: sim-l1d-retired-store-mshr
sim: sim-l1d-store-order sim-l1d-store-buffer
sim: sim-l1d-fence-behavior
sim: sim-l1d-invalidate-arbiter
sim: sim-icx-protocol-1h
sim: sim-icx-protocol-2h sim-icx-protocol-4h
sim: sim-icx-coherent-2h sim-icx-coherent-4h
sim: sim-icx-coherent-protocol-2h sim-icx-coherent-protocol-4h
sim: sim-icx-4h-l1d-directory-l2
sim: sim-icx-l2
sim: sim-icx-l2-sc-refill
sim: sim-genbus-axi sim-genbus-wb-widths
sim: sim-core-complex-1h-axi sim-core-complex-2h-axi \
	sim-core-complex-4h-wb
