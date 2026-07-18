# OpenRV64 roadmap

This roadmap is ordered by dependency, not glamour.  Correct retirement,
traps, memory ordering, observability, and Linux boot must be stable before
widening the machine.  Otherwise superscalar and out-of-order work will make
existing architectural bugs much harder to isolate.

## Current baseline

The repository currently has:

- a single-hart, single-issue, in-order IF/ID/EX/MEM/WB core;
- RV64I, RV64A, Zicsr, Zifencei, optional RV64M, and bit-manipulation
  execution.  RV64M uses one shared 8-bit iterative multiply/divide worker;
  RV64A is currently a deliberately serialized single-hart implementation
  without a coherent reservation point;
- U, S, and M privilege modes, including MRET/SRET and trap delegation;
- Sv39, a small unified TLB, a page-table walker, and PMP;
- CLINT, machine-context PLIC, UART, GPIO, timer, boot ROM, and small RAM
  blocks, but no integrated Linux-capable SoC top;
- a one-request-at-a-time blocking core/SoC memory bus;
- stall, always-taken, always-not-taken, and one-bit global-history branch
  policies, without a BTB or return-address stack;
- `mcycle`/`minstret`, a temporary `time` alias to the core clock counter, and
  the optional `openrv64-cycle-v1` pipeline/retirement trace described in
  [cycle_trace.md](cycle_trace.md);
- a saved, reproducible Cortex-A53-class HPI comparison for the
  CoreMark-derived loop in
  [performance/a53_proxy_reference.md](performance/a53_proxy_reference.md);
- WFI decode as a serializing hint that resumes immediately.  It does not yet
  stop the frontend or implement interrupt wakeup and `mstatus.TW` behavior.

Two terminology corrections matter:

- M-mode is already present.  The remaining work is architectural hardening,
  enabling RV64M in the Linux target, and supplying M-mode SBI firmware.
- RISC-V does not add a separate `H` privilege level.  The H extension turns
  S-mode into HS-mode and adds a virtualization state containing VS/VU,
  virtualization CSRs, guest traps/interrupts, and two-stage translation.

## Hard gates

Every phase must preserve these properties:

- no younger instruction changes architectural state before an older
  exception, interrupt, redirect, or debug halt is resolved;
- one versioned retirement record exists for every architectural instruction;
- the advertised ISA and privilege features exactly match implemented and
  tested behavior;
- cacheable RAM and side-effecting MMIO have explicit PMA, ordering, and error
  semantics;
- randomized and directed regressions compare against a reference model;
- synthesis, lint, and timing do not regress silently.

## Phase 0: architectural correctness and verification

This phase comes before caches, superscalar issue, or H.

### Precise exceptions and interrupts

- [ ] Turn the retirement boundary into the single authority for traps,
  interrupts, redirects, debug entry, CSR side effects, GPR writes, stores,
  and counter increments.
- [ ] Stop treating M-mode `EBREAK` as an ad-hoc permanent halt.  It must raise
  a breakpoint exception unless Debug Mode configuration requests debug entry.
- [ ] Test exception priority and `xepc`, `xcause`, and `xtval` contents for
  fetch, decode, CSR, load/store, page-walk, PMP, and bus faults.
- [ ] Test interrupt priority, enable rules, delegation, vectored/direct trap
  entry, and interrupt arrival at every pipeline boundary.
- [ ] Allow an eligible interrupt to be taken at an architectural boundary
  even when no ordinary instruction is retiring, including WFI wakeup.
- [ ] Turn the accepted WFI hint into real wait/wakeup behavior and implement
  its privilege and `mstatus.TW` rules.  Do this only after interrupts can be
  taken precisely when no ordinary instruction is retiring.
- [ ] Make supervisor timer delivery real: implement a correct SBI timer path
  that can inject STIP, or implement Sstc and `stimecmp`.
- [ ] Audit all CSR privilege checks, read-only behavior, WARL/WPRI fields,
  `mstatus`, delegation, `satp`, `SFENCE.VMA`, and `xRET` transitions against
  the ratified privileged specification.
- [ ] Define the Sv39 A/D-bit policy explicitly.  Either update A/D bits
  atomically in hardware or implement and advertise the fault-on-clear
  behavior consistently.
- [ ] Propagate mapped-target errors, not only decoder misses, through the bus
  and into the correct access-fault path.

### ISA and memory correctness

- [ ] Run the RISC-V architectural tests through RISCOF for every advertised
  extension and privilege feature.
- [ ] Add an RVFI-like retirement interface and differential execution against
  Spike or Sail.  The existing timing trace is useful but is not yet a complete
  architectural comparison record.
- [ ] Add constrained-random instruction, trap, interrupt, page-table, PMP,
  and memory-backpressure tests with reproducible seeds.
- [ ] Add assertions for request stability, one-hot ownership, no write after
  squash, in-order retirement, scoreboard balance, and trap precision.
- [ ] Define RVWMO behavior, including FENCE ordering and instruction/data
  coherence.  A single blocking bus hides many ordering bugs; caches and
  multiple outstanding requests will expose them.
- [ ] Define PMAs for cacheable/idempotent RAM, executable ROM, and ordered,
  non-cacheable, side-effecting MMIO.
- [ ] Add CI targets for simulation, architectural tests, randomized
  differential tests, lint, Yosys synthesis, and formal properties.

Exit criterion: all advertised architectural behavior passes directed,
architectural, and differential tests with precise retirement/trap records.

## Phase 1: boot single-hart Linux without caches

Linux is a correctness milestone, not a cache milestone.  Boot it through the
simple memory path first.

### CPU requirements

- [ ] Make the Linux target `rv64ima_zicsr_zifencei`.  RV64M already exists but
  is optional and disabled by default at the public top; enable and advertise
  it for this target.
- [x] Implement the first single-hart RV64A path: LR.W/D, SC.W/D, all base
  AMOs, conservative reservation invalidation, and strict ordering for
  `aq`/`rl` on the blocking bus.  Replace this implementation at the coherent
  cache/interconnect point before enabling multiple harts or DMA.
- [ ] Replace the temporary core-clock `time` CSR alias with the platform
  timebase.  `mcounteren`/`scounteren` TM access control is already present.
- [ ] Finish WFI, supervisor interrupt delivery, Sv39, PMP, and fault behavior
  from Phase 0.
- [ ] Keep C and F/D optional for the first kernel.  Add them later for a normal
  `rv64gc` distribution/userspace target; they are not reasons to delay the
  first soft-float, uncompressed kernel boot.

### Platform and firmware requirements

- [x] Add an integrated SoC top that instantiates the core, decoder, boot ROM,
  16 MiB synchronous inferred RAM, CLINT, PLIC, UART, GPIO, and timer, with
  ordered platform/core reset release and a focused end-to-end test.
- [ ] Add a configurable simulation model and explicit board
  external-memory-controller boundary alongside the inferred RAM target.
- [ ] Replace the 16 MiB inferred RAM as the Linux memory target with a
  practical configurable capacity, initially at least 128 MiB.
- [ ] Add deterministic ELF/Image, firmware, DTB, and initramfs loading to the
  simulator; do not bake a Linux image into synthesizable RAM RTL.
  The OpenSBI smoke test now has deterministic bounded firmware and DTB
  fragments; Linux Image and initramfs loading remain open.
- [ ] Boot through OpenSBI or a deliberately small compatible SBI
  implementation in M-mode, then enter Linux in S-mode.
  Pinned OpenSBI v1.9 now reaches and validates an S-mode SBI payload; Linux
  entry remains open.
- [ ] Supply a device tree describing the hart ISA, timebase, RAM, reserved
  firmware memory, UART, CLINT/ACLINT, PLIC, and chosen boot arguments.
  The smoke DT covers the hart, timebase, 16 MiB RAM, UART, CLINT, and PLIC;
  Linux reserved-memory and chosen boot arguments remain open.
- [ ] Meet the Linux entry contract: `a0=hartid`, `a1=DTB address`, `satp=0`,
  and the RV64 kernel image placed on a 2 MiB boundary.
- [ ] Provide a working UART console and timer interrupt path.  Add a
  supervisor PLIC context only if the chosen firmware/platform routing needs
  SEIP directly; an M-mode-only path must still be complete and documented.
- [ ] Validate CLINT/PLIC delivery through the complete platform, not only
  peripheral unit tests: simultaneous sources, priority/threshold, claim and
  completion, level reassertion, delegation/routing, masking, and arrival at
  every pipeline boundary.
  The initial platform test now covers simultaneous PLIC sources,
  priority/threshold, claim/completion, device clearing, MSIP/MTIP/MEIP
  routing, architectural causes, and trap-handler arrival. Delegation, masking
  matrices, reassertion, and every pipeline boundary remain open.
- [ ] For the first firmware, implement only the SBI surface the pinned kernel
  actually exercises (base/probing, timer, console or debug console, reset,
  and the required single-hart context transition).  Unsupported extensions
  must return the specified error rather than silently succeeding.

### Linux exit tests

- [ ] Boot OpenSBI and a pinned Linux configuration to an initramfs shell.
- [ ] Run a U-mode process, system calls, demand paging, timer preemption, and
  UART interrupts.
- [ ] Exercise page faults, illegal instructions, unaligned accesses, and
  access faults without losing precise state.
- [ ] Save the kernel, OpenSBI, compiler, DTB, and rootfs versions plus the full
  console log as a reproducible regression artifact.

For a more useful Linux system after the first shell, add virtio-mmio block and
network devices.  PCIe, an IOMMU, and DMA are later platform features, not
first-boot requirements.

## Phase 2: profiling, trace, and architectural debug

These facilities must exist before performance work is trusted and before OOO
recovery is debugged.

### Profiling and trace

- [ ] Preserve `openrv64-cycle-v1`; introduce a new schema version rather than
  silently changing existing fields.
- [ ] Extend retirement records with privilege/virtualization state, trap
  interrupt flag and `tval`, source values when useful, CSR address/read/write
  data, and load/store virtual address, physical address, data, size, and mask.
- [ ] Add branch prediction/resolution, mispredict reason/target, TLB/PTW, and
  cache hit/miss/refill/writeback events as those blocks are implemented.
- [ ] Add selected `mhpmcounter`/`mhpmevent` pairs for retired instructions,
  branches, mispredicts, exceptions, interrupts, frontend starvation, hazard
  stalls, memory stalls, TLB misses, and cache misses.  Define inhibit,
  privilege filtering, overflow, and reset behavior.
- [ ] Symbolize traces from ELF files and report per-function cycles, retired
  instructions, IPC, stalls, branch misses, and cache/TLB misses.
- [ ] Add trace filters and triggers by PC range, privilege, event, and cycle
  window.  For FPGA use, stream or buffer trace rather than exporting an
  unbounded set of top-level pins.
- [ ] Consider the ratified RISC-V trace specifications only after the internal
  retirement/event contract is stable; standard encoding is not a substitute
  for correct source events.

### Debug

- [ ] Implement RISC-V Debug Specification 1.0 Debug Mode separately from
  architectural traps and from the current `dbg_halted` test convenience.
- [ ] Add `dcsr`, `dpc`, `dscratch*`, `DRET`, single-step, halt-on-reset, and
  precise halt/resume at the retirement boundary.
- [ ] Add a minimal Debug Module with hart discovery/status, halt/resume/reset,
  and abstract GPR access.
- [ ] Support at least one useful memory/register mechanism: a program buffer,
  abstract memory access, or System Bus Access.  Prefer System Bus Access plus
  abstract GPR/CSR access for bring-up.
- [ ] Add execution/data-address triggers and correct EBREAK-to-debug controls.
- [ ] Add DMI and a JTAG DTM, then validate OpenOCD/GDB register access,
  breakpoints, watchpoints, memory access, single-step, reset-halt, and resume.
- [ ] Specify debug interaction with outstanding memory operations, caches,
  LR/SC reservations, interrupts, and later ROB/LSQ state.

Exit criterion: a Linux or bare-metal workload can be profiled reproducibly and
debugged through GDB without relying on hierarchical testbench peeks.

## Phase 3: memory hierarchy and interconnect

The current blocking bus cannot support a serious cache hierarchy or OOO core
without becoming the bottleneck.

- [ ] Define separate frontend and LSU request interfaces and a downstream
  memory-hierarchy protocol with size, command, response error, IDs, bursts,
  backpressure, and multiple outstanding transactions.
- [ ] Preserve a simple ordered MMIO bridge so peripherals do not need to
  implement the high-performance protocol.
- [ ] Implement split L1 I-cache and D-cache first, with configurable line,
  set, way, replacement, refill, and write policy.
- [ ] Bypass caches for MMIO/PMA-uncacheable accesses and serialize their side
  effects.
- [ ] Make FENCE.I invalidate or otherwise synchronize instruction fetch after
  stores; make SFENCE.VMA and page-table writes interact correctly with the
  TLB/PTW and caches.
- [ ] Integrate LR/SC reservations and AMOs at the coherence point.
- [ ] Add parity/ECC hooks, error injection, refill/writeback fault handling,
  and cache-maintenance observability.
- [ ] Add a unified L2 only after L1 is correct and measured.

On a single-hart design, that unified L2 is already the last-level cache.  Do
not create both an L2 and a separately named LLC unless there is a defined L3
or shared multicore topology that benefits from it.

### If a distinct shared LLC is required

- [ ] Decide hart count and topology first.
- [ ] Add a coherent interconnect and a specified coherence protocol.
- [ ] Make LR/SC reservations, AMOs, I-cache coherence, DMA, and debug System
  Bus Access participate correctly in coherence.
- [ ] Add per-hart CLINT state, PLIC M/S contexts, IPIs, cache/TLB shootdown,
  and Linux SMP boot tests.
- [ ] Define inclusive, exclusive, or non-inclusive L2/LLC policy and prove
  eviction, intervention, and error behavior.

Exit criterion: randomized memory tests and Linux stress tests pass with
backpressure, evictions, aliases, fences, atomics, and injected faults.

## Phase 4: branch prediction and frontend

- [ ] Add a PC-indexed table of two-bit direction counters as the first real
  conditional predictor.
- [ ] Add a tagged BTB for taken target prediction and a return-address stack
  for calls/returns.  The current direct-target calculation does not solve
  indirect JALR prediction.
- [ ] Add prediction metadata that follows each instruction to resolution and
  trains only on valid, non-squashed outcomes.
- [ ] Add mispredict recovery tests for branches, JAL, JALR, traps, fences, and
  back-to-back redirects.
- [ ] Measure MPKI, wrong-path work, IPC, area, and Fmax on more than one tiny
  loop before adopting gshare, TAGE, or larger structures.
- [ ] Design predictor checkpoints and restore semantics before OOO work.

Exit criterion: the predictor beats the simple policies on a reproducible
workload suite without reducing total performance through area or timing loss.

## Phase 5: H extension

Implement H before superscalar/OOO if virtualization is a firm requirement.
Retrofitting guest architectural state, two-stage faults, and virtual
interrupts after an ROB and LSQ exist is substantially harder.

- [ ] Add virtualization state `V`; define M, HS, U, VS, and VU transitions
  and privilege checks.
- [ ] Implement the required H and VS CSRs, including `hstatus`, delegation and
  virtual interrupt CSRs, `vsstatus`/`vsepc`/`vscause`/`vstval`/`vstvec`,
  `vsatp`, `hgatp`, `htval`, `htinst`, `mtval2`, and `mtinst` as applicable.
- [ ] Implement VS-stage plus G-stage translation, guest-page faults, VMID/ASID
  tagging, PMP/PMA checks, and correct fault-address reporting.
- [ ] Implement HFENCE.VVMA, HFENCE.GVMA, HLV/HLVX/HSV, virtual-instruction
  exceptions, guest trap delegation, virtual timers, and virtual interrupts.
- [ ] Extend trace, counters, debug, and differential tests with virtualization
  state and both translation stages.
- [ ] Advertise `misa.H` only when the mandatory H behavior is complete.
- [ ] Boot Linux in HS-mode and then boot a VS-mode guest under KVM or a small
  reference hypervisor.

Exit criterion: architecturally tested two-stage translation and traps, plus a
repeatable guest boot.  Merely reaching HS-mode is not H-extension completion.

## Phase 6: two-wide in-order superscalar

“Superscalar” here means a concrete two-wide in-order machine, not only a
wider fetch bus.

- [ ] Widen fetch, alignment, decode, dispatch, operand read, writeback, and
  retirement with explicit lane ordering.
- [ ] Define legal dual-issue pairs and same-cycle RAW/WAW dependencies.
- [ ] Add sufficient register-file ports or a banked/bypassed design.
- [ ] Replicate or pipeline execution units based on measured contention.
- [ ] Support two memory operations only after the D-cache interface can
  accept them, or explicitly restrict issue to one memory operation per cycle.
- [ ] Preserve precise exceptions and interrupts when the older lane succeeds
  and the younger lane faults.
- [ ] Serialize CSR, fence, return, debug, and other non-ordinary operations.
- [ ] Measure IPC, Fmax, area, and power; keep single-issue mode as a reference.

Exit criterion: two-wide retirement improves real workloads and passes the
same architectural/differential suite under all legal lane combinations.

## Phase 7: out-of-order execution

OOO is the final core-architecture phase and must reuse the established
retirement, memory, prediction, trace, and debug contracts.

- [ ] Add register renaming, physical register allocation/freeing, a rename
  map, and committed-map recovery.
- [ ] Add a ROB that is the sole in-order authority for retirement, precise
  traps, interrupts, debug entry, stores, and architectural counters.
- [ ] Add issue queues, wakeup/select, operand readiness, and multi-cycle
  execution completion tracking.
- [ ] Add an LSQ and store buffer with forwarding, ordering violation
  detection, replay, RVWMO enforcement, atomics, fences, and uncached MMIO
  serialization.
- [ ] Add branch checkpoints and complete rename/ROB/issue/LSQ recovery on
  mispredict, trap, interrupt, and debug halt.
- [ ] Define replay and recovery for cache misses, TLB misses, page walks,
  access faults, and machine checks.
- [ ] Extend trace to distinguish fetch, dispatch, execute completion, replay,
  squash, and architectural retirement without exposing unstable internal IDs
  as architectural state.
- [ ] Use formal invariants for physical-register ownership, ROB ordering,
  no-squashed-side-effects, store visibility, and precise recovery.

Exit criterion: OOO produces the same retirement stream as the reference model
under randomized latency, faults, interrupts, mispredictions, and debug events,
and gives a measured performance win after Fmax and cache effects are included.

## Cross-cutting implementation work

- [ ] Select an FPGA/ASIC target and track synthesis area, BRAM/SRAM use, Fmax,
  critical paths, and reset/clock-domain assumptions for every major phase.
- [ ] Add reproducible benchmark suites: directed microbenchmarks, CoreMark or
  Embench, Linux boot/time-to-shell, and representative user workloads.
- [ ] Version all externally consumed contracts: bus, retirement trace, PMU
  events, debug transport, device tree, and boot image layout.
- [ ] Keep optional features parameterized, but do not permit a configuration
  to advertise behavior it has compiled out.
- [ ] Document known deviations from each ratified specification next to the
  relevant acceptance tests.

## Standards and external contracts

- [Linux RISC-V boot requirements](https://docs.kernel.org/arch/riscv/boot.html)
- [RISC-V privileged architecture and H extension](https://docs.riscv.org/reference/isa/priv/hypervisor)
- [RISC-V A extension](https://docs.riscv.org/reference/isa/unpriv/a-st-ext.html)
- [RISC-V Debug Specification 1.0](https://docs.riscv.org/reference/debug/)
- [OpenSBI](https://github.com/riscv-software-src/opensbi)
- [RISC-V architectural tests](https://github.com/riscv-non-isa/riscv-arch-test)
