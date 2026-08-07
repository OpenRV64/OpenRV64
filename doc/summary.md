# OpenRV64 current status and productization gap

Audit date: 2026-08-06 UTC

Post-audit licensing/status corrections: 2026-08-07 UTC

Audited revision: `821a2c0860793a579600f8c782ab136e034b962a` plus the then-current dirty working tree

## Executive judgment

OpenRV64 is a substantial CPU research and simulation platform. It is not a
product-ready processor or SoC.

The strongest part is the RV64 integer 3-pipeline implementation and its
simulation environment: it boots Linux in one-, two-, and four-hart test
harnesses, passes a useful deterministic user-mode SMP suite, has broad directed
cache/coherence/atomic/VM testing, and has historical limited ACT4 results. The
repository also contains working but separate F/D and private vector paths,
several memory-system models, performance experiments, and synthesis scripts.

The main deficiency is not a missing isolated instruction. The repository does
not yet define, close, or continuously validate one production configuration.
The public tops, simulation-only coherent hierarchy, 4PF F/D top, private vector
top and simulation platforms expose different feature sets. The aggregate
regression is red in the audited tree. Current physical evidence is pre-layout and excludes
important memories or subsystems. DFT, production debug, reliability protection,
power/reset intent, signoff, and a documented microarchitectural side-channel
policy are absent.

Accordingly:

- **Research RTL and Linux-capable simulation:** viable.
- **FPGA evaluation image:** no current tracked target; the prior MYIR/Artix-7
  target was removed pending provenance and redistribution review.
- **Deployable FPGA SoC:** no.
- **ASIC tapeout candidate:** no.
- **Product security or safety assurance:** no supporting closure evidence.

This is an evidence classification, not a judgment about eventual feasibility.
Most blockers are normal productization work, but their combined scope is large.

## Evidence and audit boundary

This report used RTL and build-source inspection, repository documentation,
retained result artifacts, and representative current-tree regressions. A
passing directed test is treated as evidence for the behavior it checks, not as
general proof of correctness. Cycle-model results are not treated as silicon
frequency, memory bandwidth, or power measurements.

The working tree was already dirty. In particular, it contained uncommitted L1D
synchronous-tag and test/build changes. They were preserved. Recent retained
Linux runs cover the committed L2 refactor state and their recorded patches; they
do **not** validate the later uncommitted L1D changes. Those changes passed the
focused L1D/cache group run during this audit.

### Current-tree tests run during this audit

| Command/group | Result | What it establishes | Important limit |
|---|---:|---|---|
| `make -j8 sim` | **FAIL** | The aggregate gate was exercised. | `tb_openrv64_top.sv` fatals because the expected conditional-branch predictor stall is never observed. The test assumes behavior not provided by the current BP8 default. Regardless of whether the RTL or test contract is wrong, the repository-wide gate is red. |
| L1 sync tags, prefetch, demand MSHRs, store ordering/buffering, L1 cache, native L2, L2-to-AXI DDR3, four-L1D directory/L2 | PASS | Directed cache pipeline, refill, store forwarding/combining, eviction, native atomics, adaptive prefetch, concurrent L2 traffic, and a 2,048-round/8,192-operation four-client coherence stress passed. | Deterministic simulation; not exhaustive coherence proof, analog DDR evidence, ECC testing, or reset/fault testing. |
| 3P execution/backend/top, Zicclsm context, 4PF F/D top and fault tests, private vector tests, local compliance smokes | PASS | Current paths elaborate and complete their directed architectural tests. Full-core 4PF DAXPY and trap/fault continuation pass. | The compliance smokes are not the ACT4 suite. F/D and vector do not share the principal 1P/3P product top. |
| `make check-fence-sv39` | PASS | All nine directed fence/Sv39 cases, atomic hierarchy cases, LSU RV64A, and atomic-context tests passed with exact request/completion counts and zero reported violation masks. | This is not an RVWMO proof or broad multi-hart litmus campaign. The memory model is controlled simulation. |

The two focused groups were invoked as:

```text
make -j8 sim-l1-sync-tag sim-l1d-prefetch sim-l1d-demand-mshr \
  sim-l1d-store-order sim-l1d-store-buffer sim-l1-cache sim-icx-l2 \
  sim-l2-axi-ddr3 sim-icx-4h-l1d-directory-l2

make -j8 sim-exec-top-3p sim-backend-3p sim-top-axi-3p \
  sim-zicclsm-context sim-top-4pf sim-top-4pf-faults sim-vec \
  compliance-smoke-local
```

The aggregate failure means the audited checkout must not be described as
“all tests passing.” Focused groups pass, but the top-level contract and default
configuration have drifted apart.

### Retained regression evidence

- Historical local ACT4 JSON summaries record 93 passing tests for the 1P, 3P,
  platform-1P, and platform-3P configurations, plus three privileged `Svbare`
  tests. The artifacts are from 2026-07-22/23 and cover a limited
  I/M/A/Zicsr/Zifencei set. The adapter was removed on 2026-08-07 pending clean
  provenance and licensing, so the current tree cannot reproduce those results.
  They do not cover Sv39, Zicclsm, Zbb, F/D, or the private vector
  implementation. See
  [verification/compliance/README.md](../verification/compliance/README.md).
- Managed Linux runs retain validated one-, two-, and four-hart boots. The two-
  and four-hart L2-refactor runs ended at the literal `openrv64# ` prompt, exited
  cleanly, and reported `OPENRV64_USER_SUITE_END status=PASS passed=12 failed=0
  skipped=0` plus `PTHREAD_LOCK_PASS`. The one-hart control correctly skipped
  SMP-only cases. The suite exercises affinity, atomics, CAS handoff, locks,
  cache-line/page sharing, VA aliasing, remote mapping changes, and futexes. See
  [tests/linux-user-mode.md](tests/linux-user-mode.md).
- Those Linux results are strong integration evidence, but they are short,
  deterministic simulator runs. They are not a distribution qualification,
  stress soak, board result, full RVWMO campaign, or proof across all parameter
  combinations.

## Implemented system

### Core variants and integration state

| Variant | Current role | Status |
|---|---|---|
| `openrv64_top` | Generic 1P-by-default wrapper over the blocking memory bus; can select 3P. | Principal simple integration surface. It exposes optional Zbb. |
| `openrv64_top_3p` | Fixed 3P native-ICX/residual-AXI top with 16-entry retirement, BP8 default, optional issue/speculation, A, optional M, and Zicclsm. | Most capable integer core surface. It does not expose the documented Zbb parameter, despite the inner 3P core supporting it. |
| `soc/platform.sv` | Synthesizable single-hart platform with boot ROM, CLINT/PLIC/UART and selectable memory models. | Linux simulation vehicle. The external-memory seam is intentionally limited to 1P. |
| `tb_4h_3p.sv` hierarchy | One-to-four real 3P cores, coherent home/directory/L2, residual AXI and platform devices. | Demonstrates SMP Linux in simulation. It is a testbench hierarchy, not a production SoC wrapper. |
| `top_4pf.v` | Separate four-pipeline F/D-capable execution top. | Directed full-core F/D behavior works, but it is not integrated into the main 1P/3P/Linux platform. |
| `openrv64_vec_test_top.sv` | Private vector coprocessor/test integration. | Functional test vehicle. It is explicitly not a standard RVV architectural implementation. |
| `wrapper_nh.v` | Generated 1–16 hart transport wrapper. | Multi-core transport only; not the coherent Linux hierarchy. |

The variant split is acceptable for experimentation but unsafe as a product
definition. Feature claims must name the exact top and parameter set.

### ISA and privilege support

The integrated integer cores implement RV64I with optional M and A,
Zicsr/Zifencei, M/S/U privilege, traps/interrupts, PMP, Sv39/Bare translation,
and a 3P Zicclsm path. A gated Zbb implementation exists in the inner 3P path.
There is no compressed-instruction implementation. Public parameter defaults do
not consistently describe the Linux-capable feature set: M is off in important
tops although Linux harnesses enable it.

Material qualifications:

- F/D support is a separate 4PF integration, not part of the public integer
  product configurations. It has useful directed execution/fault evidence but no
  corresponding full compliance campaign.
- Zbb is default-off and is not consistently surfaced through the fixed 3P top.
  ISA discovery/advertisement is also not a complete product contract.
- The vector unit is a private interface and instruction path. It lacks standard
  RVV decode, architectural CSRs, restart semantics, and software ABI support.
- `mstatus.TW` storage exists, but lower-privilege WFI interception remains an
  architectural TODO.
- PMP provides 16 entries at 4 KiB granularity with OFF/NAPOT support. TOR and
  NA4 are not implemented as usable matching modes.

### Pipeline and speculation

The 3P core fetches, decodes, and allocates up to three instructions per cycle,
uses EX0/EX1/MEM paths, and retires in order from a 16-entry queue. It supports
optional issue-window/speculative behavior but is not a conventional renamed
out-of-order core.

Speculative cacheable loads may execute past unresolved branches after
translation. Wrong-path architectural responses are discarded, but cache,
prefetch, predictor, and translation state can still be changed. There is no
repository-level threat model that states which cross-domain observations are
allowed, nor a verification plan for predictor/cache/TLB/prefetch leakage or
privilege-transition cleanup. That is a product security blocker, not merely a
performance TODO.

### Memory hierarchy, coherence, and VM

The repository contains 16 KiB L1I and 16 KiB write-through L1D designs, a
256 KiB eight-way L2, a 512-bit-line native ICX path, three L1D demand MSHRs, an
eight-line store buffer, adaptive prefetch, a coherent home/directory, and
fixed-latency/AXI/timed-DDR simulation backends.

Sv39 support includes micro-TLBs, a larger main TLB, a blocking PTW, and a
non-leaf PTE cache. The implementation intentionally faults on clear A/D bits
rather than updating them. Selective `SFENCE.VMA` behavior is reduced to a local
global flush. The coherent PTE-generation mechanism is only eight bits wide, so
generation wrap after 256 relevant invalidation events requires a specified and
verified recovery rule.

The coherent hierarchy has passed substantial directed testing and Linux SMP,
but several product contracts remain incomplete:

- no supported synthesizable multi-hart SoC top combines the proven hierarchy,
  reset/interrupt wiring, memory controller, and platform devices;
- L1I has no complete probe/coherence endpoint for arbitrary cross-hart code
  modification;
- acquire/release information and full fence ordering need a single end-to-end
  architectural specification rather than local assumptions at different buses;
- posted-store asynchronous error reporting and machine-check behavior are not
  defined;
- residual AXI, native ICX, probe, invalidation, reset, and error behavior need
  protocol assertions and adversarial backpressure testing;
- the globally serialized home simplifies correctness but may become an SMP
  bottleneck. Existing tests establish function, not scalable throughput.

## Performance and physical evidence

The performance documents contain useful cycle-level characterization, not a
product performance claim. The current report records a finite CoreMark-derived
loop at 56,146 cycles and 0.9363 IPC and STREAM-like 64 KiB kernels at roughly
3.4 B/cycle for copy/scale and 2.13 B/cycle for add/triad. These numbers depend
on the simulator's cache and backing-memory timing. They are not CoreMark/MHz,
DRAM bandwidth, or board measurements. See
[performance/current.md](performance/current.md).

Known throughput limits include a single translation/L1D launch opportunity,
finite load/store queue resources, frontend refill stalls, and in-order
retirement. BP8 and the more aggressive backend improve some workloads, but
frequency and area effects have not been closed.

Physical evidence is not yet signoff-grade:

- The older Sky130 reports are mapped standard-cell estimates, pre-layout, and
  omit or separately account for significant memory structures. Historical
  worst combinational paths cannot be converted into a supportable clock target.
  See [physical/size.md](physical/size.md) and
  [physical/timing.md](physical/timing.md).
- A newer Nangate45 cacheless 4PF comparison reports about 1.3715 mm2 without
  F/D and 2.3628 mm2 with F/D. It deliberately excludes L1 and leaves other
  memories unpriced. The approximately 0.9913 mm2 F/D delta is useful for
  comparison only. See [pd/whole-chip.md](pd/whole-chip.md).
- There is no floorplanned full chip with SRAM macros, extracted interconnect,
  clocks, corners, on-chip variation, IR/EM analysis, or power closure.
- There is no supported frequency, voltage, power, thermal, die-size, or yield
  claim.

The previous MYIR/Artix-7 target was removed from tracked source on 2026-08-07
pending provenance and redistribution review. No current FPGA build, timing, or
board-operation result is claimed.

## Productization blockers

### P0: define and continuously validate one product

1. **Freeze a supported configuration.** Select the ISA, privilege modes, core
   top, pipeline/backend options, cache sizes, coherence topology, hart count,
   reset map, interrupt map, and external buses. Reject unsupported parameter
   combinations at elaboration. Today the parameter space is larger than the
   validation matrix.
2. **Create a production top.** The coherent Linux hierarchy must move from a
   testbench composition into a synthesizable, documented SoC/core-complex top
   with stable clocks, resets, interrupts, error reporting, debug, and memory
   interfaces.
3. **Restore a green default gate.** Resolve the BP8 versus legacy-stall
   expectation in `tb_openrv64_top.sv`, define which defaults are normative, and
   make aggregate regressions mandatory. A repository whose principal regression
   fails cannot support release claims.
4. **Make results source-identifiable.** Every release result should record the
   exact commit, dirty patch/hash, tool versions, configuration, seed, expected
   assertions, and completion markers. Retained managed Linux runs already move
   in this direction; all major regressions need the same discipline.
5. **Reconcile the ISA interfaces.** Integrate or explicitly exclude F/D, Zbb,
   Zicclsm, C, and vector support. Align hardware discovery, device tree, hwprobe,
   toolchain multilib/ABI, and compliance targets with the selected product.

### P0: close architectural correctness

1. Run a current clean-tree architectural suite over the frozen configuration,
   including full applicable externally maintained ACT4/RISCOF coverage for
   integer, privilege, VM, A, Zicclsm/Zbb, and F/D if claimed. Any local adapter
   must have explicit origin, notices, and licensing.
2. Add differential random instruction testing against an independent reference
   model, with interrupts, exceptions, page faults, PMP changes, self-modifying
   code, and asynchronous backpressure. Encoding-only unit tests are not enough.
3. Build a systematic RVWMO and atomic campaign using litmus tests, multiple
   harts, mixed cached/MMIO accesses, `aq`/`rl`, all fence predecessor/successor
   combinations, DMA/coherent agents, and variable response reordering.
4. Resolve the documented architectural gaps: TW/WFI interception, selective
   `SFENCE.VMA` semantics, PTE A/D policy and software contract, PTE-generation
   wrap, executable-memory coherence, PMP mode policy, and asynchronous errors.
5. Add formal properties or equivalent exhaustive checking for retirement
   precision, privilege isolation, PMP-after-translation enforcement, TLB
   invalidation, store ordering, coherence invariants, reservation lifetime,
   and no stale response acceptance after flush/reset/generation changes.
6. Complete the aligned/misaligned/page-crossing/PMP/atomic fault matrix. The
   existing unaligned testing is useful but remains an explicitly tracked
   verification area; see [TODO/verif/unaligned.md](TODO/verif/unaligned.md).

### P1: silicon implementation and reliability

1. Infer or instantiate characterized SRAM/register-file macros for all major
   arrays, with repair/ECC/parity decisions and error injection. Current mapped
   flop/mux estimates do not represent a chip.
2. Establish synthesis, STA, floorplan, placement, CTS, routing, SI, CDC/RDC,
   reset-domain, IR/EM, power, and multi-corner signoff flows. Define real clock
   and I/O constraints rather than extrapolating from combinational reports.
3. Specify reset sequencing, clock gating, power states, retention, warm reset,
   watchdog, fatal/nonfatal error handling, and recovery from partial cache/TLB/
   coherence transactions.
4. Add DFT: scan strategy, memory BIST/repair, JTAG/boundary scan as required,
   test modes, coverage targets, and ATPG signoff. The repository currently has
   no DFT architecture.
5. Add a production RISC-V debug module and trace/performance-monitoring policy.
   Simulation `$display` traces are not a field-debug facility.
6. Quantify FIT/reliability requirements and protection coverage. Cache tags,
   data, TLBs, retirement state, interconnect metadata, and control FSMs have no
   demonstrated parity/ECC or recovery plan.

### P1: security verification

1. Write a threat model covering privilege domains, mutually distrustful harts,
   guest/host assumptions if virtualization is ever claimed, DMA, debug, fault
   injection, and physical versus software attackers.
2. Specify permitted speculative side effects. Test branch/load speculation,
   predictor state, prefetch state, cache replacement, TLB/PTW state, faulting
   accesses, and privilege transitions with adversarial instruction sequences.
3. Verify PMP/PMA and page permission enforcement at every request and replay
   seam, including stale translations, split accesses, AMOs, cache refill/write
   back, MMIO, and debug/DMA access.
4. Decide whether predictor/cache/TLB/prefetch state requires flush, partitioning,
   tagging, fencing, or documentation as an accepted leakage channel.
5. Add protocol assertions and fault injection for malformed responses, dropped
   probes, duplicate/stale completions, ECC/parity errors, and timeout/deadlock.

### P2: software, release, and maintainability

1. Add continuous integration for lint, elaboration, directed tests, compliance,
   randomized seeds, synthesis smoke, documentation checks, and at least a
   bounded Linux boot. No repository CI configuration was present in this audit.
2. Reduce the warning baseline. Current builds report implicit nets such as
   `ras_return_fetch_valid`, inherited timescales, dangling error ports, and
   unconsumed response errors. Enable `default_nettype none` or equivalent
   discipline and make meaningful warnings fatal.
3. Replace contradictory status prose with generated/versioned feature and test
   manifests. Examples of current drift include:
   - [architecture.md](architecture.md) still describes an older retirement
     depth/branch-forwarding default and understates the working four-hart test
     hierarchy;
   - [ordering/fence-suite.md](ordering/fence-suite.md) records an old FAIL even
     though the current suite passes;
   - [integration/icx-coherent-variants.md](integration/icx-coherent-variants.md)
     retains unchecked Linux/timed-DDR items superseded by later runs;
   - the compliance README's PMP description no longer matches the RTL;
   - F/D cycle counts in prose have already drifted from current execution.
4. Pin or package toolchains, external ACT4/Sail inputs, simulators, synthesis
   tools, Linux,
   OpenSBI, firmware, and workload images. Network-fetched or locally assumed
   dependencies must be reproducible for a release.
5. Complete project-wide source licensing and provenance hygiene. The top-level
   CERN-OHL-P-2.0 license and NOTICE provide a basis, but only a small fraction of
   tracked source/script files carry SPDX identifiers.
6. Provide board boot, recovery/update, manufacturing-test, diagnostics, crash
   capture, and version-reporting flows. A bitstream alone is not a product image.

## Recommended exit gates

### Gate A: trustworthy baseline

- one frozen configuration and production top;
- clean worktree, warning policy defined, aggregate regression green;
- reproducible manifests for tools and images;
- documentation generated or checked against RTL defaults;
- current source-matched compliance and Linux evidence.

### Gate B: architecture closure

- applicable ISA/privilege/VM compliance complete;
- differential random and multi-hart RVWMO campaigns clean over meaningful seeds;
- formal/coherence/PMP/TLB properties closed or exceptions explicitly justified;
- all error, reset, fence, atomic, I-cache-coherence, and generation-wrap
  contracts specified and tested;
- security threat model and speculative-state policy approved.

### Gate C: deployable FPGA prototype

- board DDR calibration and stress demonstrated;
- OpenSBI and Linux loaded and booted on hardware;
- production clock/reset/debug/error paths exercised;
- long-running multicore, VM, atomic, DMA, and peripheral stress passes;
- measured board frequency, bandwidth, power, and thermal behavior reported.

### Gate D: ASIC readiness

- SRAM/clock/power/DFT/debug architecture complete;
- full-chip PPA with extracted layout and signoff corners;
- CDC/RDC, lint, formal, STA, SI, IR/EM, DRC/LVS, ATPG, and reliability targets
  closed;
- release verification repeated on the exact netlist/layout-bound source;
- manufacturing, bring-up, security response, and field-update plans exist.

The immediate priority should be Gate A, not adding more optional execution
features. Until there is one source-matched green product configuration, each new
variant increases the verification problem faster than it increases product
readiness.
