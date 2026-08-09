# RAS/BTB context-alias regression

## Status

The reproduced single-hart Linux failure is contained, and a fresh timed-DDR3
boot reaches the interactive shell. The underlying target-predictor design bug
is not fixed.

The observed failure was specifically a **BTB alias on an indirect call**. It
was not a RAS prediction, despite the broader RAS/BTB name used while debugging.
The RAS had the same unsafe context-lifetime problem and was hardened during the
investigation, but it did not supply the failing target.

The temporary policy is:

- do not apply branch-predictor redirects while executing in M-mode;
- treat the same M-mode control as not predicted in the metadata sent to the
  backend, so recovery agrees with fetch;
- flush the RAS on architectural control flushes; and
- permit L1I speculative prefetch/side-fetch activity only in Sv39.

2-hart and 4-hart Linux validation was deliberately held until this single-core
failure was understood. The successful run described below has one active hart;
harts 1-3 are held in reset and omitted from the device tree.

## Failure

The failing configuration was the BP8/tournament predictor on the coherent 4H
rig with one active hart, Zicclsm and Zbb enabled, timed DDR3, one Verilator
thread, and DDR bank/row swizzling disabled. A checkpoint was saved at
155,000,000 cycles.

The source-matched replay failed deterministically at cycle 156,660,600:

```text
malformed/out-of-range L2 request
addr=ffffffff800f0980 size=6 write=0 cacheable=1
```

Primary artifacts:

- original checkpoint/failure:
  `run/log/linux-l1-zbb-regression-1h-ddr3-20260808T230554Z/`
- L2 and L1I replay:
  `run/log/linux-l1-zbb-regression-1h-ddr3-20260809T022020Z/`
- focused fetch-path replay:
  `run/log/linux-l1-zbb-regression-1h-ddr3-20260809T023044Z/`
- fresh contained boot:
  `run/log/linux-l1-zbb-regression-1h-ddr3-20260809T033043Z/`

All four runs record Git HEAD
`c13d8dc5d4ed2f277472e8beb3aa4cf572cf2de5`; their per-run worktree patches
distinguish the uncommitted RTL used by each run.

## Root cause

### Confirmed event chain

The tournament BTB is direct-mapped with 256 entries and a 16-bit tag:

```text
index = PC[9:2]
tag   = PC[25:10]
```

Consequently, a hit compares only `PC[25:2]`. It stores neither the remaining
PC bits nor privilege, effective VM mode, ASID, or address-space generation.

Linux previously executed an S-mode return at virtual PC
`0xffffffff8010a444` whose target was `0xffffffff800f0990`. The retirement
trace shows, for example:

```text
cycle 156619378  priv=S  pc=ffffffff8010a444  instr=00008067
cycle 156619381  priv=S  pc=ffffffff800f0990
```

The BTB trains on every resolved, taken `JALR`, including returns even though
return lookup normally selects the RAS. That S-mode return therefore populated
the BTB entry with target `0xffffffff800f0990`.

Later, OpenSBI executed an M-mode indirect call at physical PC
`0x000000008010a444`. Its low PC bits are identical to the S-mode return:

```text
S source: ffffffff8010a444
M source: 000000008010a444
matched:                   PC[25:2]
```

The focused trace records the bad lookup and redirect:

```text
cycle 156660583  priv=M  lookup_pc=8010a444  instr=000780e7
                 indirect=1 target_valid=1
                 predicted_target=ffffffff800f0990
cycle 156660587  predictor redirect applied to ffffffff800f0990
cycle 156660588  demand fetch requested at ffffffff800f0980
cycle 156660598  L2 read issued at ffffffff800f0980
cycle 156660600  malformed/out-of-range L2 request fatal
```

`0x000780e7` is an indirect call (`jalr x1, 0(x15)`), not a return, so the
predictor selected the BTB entry rather than the RAS. This distinction is
confirmed by both the instruction encoding and the predictor selection logic.

Instruction translation is architecturally disabled in M-mode in this design.
`rv64_top_3p.v` therefore presents effective fetch mode BARE even though the
`satp` CSR still contains Sv39 state. The aliased S-mode virtual target was
treated as an M-mode physical address. The current PMP policy allowed the
M-mode fetch, so the invalid address reached L1I and then L2. The testbench's
range assertion stopped it before the external memory model.

The immediate root cause is therefore:

> Context-blind partial BTB tags allowed an S-mode virtual return target to be
> consumed by an M-mode physical indirect call at an aliasing low PC.

### RAS relationship

The RAS was not the target source in the failing cycle. It was nevertheless
unsafe across architectural context transitions:

- it held full targets without privilege/address-space identity;
- ordinary predictor squashes and architectural context changes used the same
  flush input; and
- RAS-directed L1I side fetches could previously run in M-mode.

The investigation split wrong-path squash handling from architectural RAS
flush handling and connects architectural `control_flush` to the latter.
Trap entry, `mret`, `sret`, SATP changes, fences, and other architectural
restarts included in `control_flush` now clear the RAS. Ordinary branch recovery
only clears pending speculative-call accounting.

### Why the failure appeared now

The context-alias defect is older than the cache work that exposed it:

- `1f46e48` introduced the 256-entry indirect BTB with a 16-bit partial tag and
  no execution-context identity.
- `dcbc06c` introduced BP8/tournament prediction using the same BTB geometry;
  this is the predictor used by the failing Linux configuration.
- `1e42762` added RAS-directed fetches and multiple outstanding L1I demand
  requests. That increased the frontend's ability to propagate a predicted
  target, but the observed event remained a BTB hit.
- `72cef91` and subsequent worktree changes moved the L1 toward synchronous
  SRAM-friendly lookup and changed frontend/cache timing.

The first two changes created the correctness defect. The latter changes are
an exposure mechanism: they changed event ordering enough for the rare alias to
become reproducible late in boot. There is no commit-level bisect proving that
one particular synchronous-L1 change is necessary for the alias. Calling the
cache refactor the root cause would be incorrect.

## Debugging process

1. A fresh Linux run saved a 155M-cycle checkpoint, then failed consistently at
   156.6606M with a sign-extended instruction-fetch address at L2.
2. The first hypotheses were a bad PTE, a PMP escape, address corruption, or an
   L1I prefetch crossing a translation/context boundary.
3. L2 and L1I tracing established that this was an instruction demand generated
   after the frontend changed PC; it was not an arbitrary data corruption.
4. L1I prefetch and side-fetch activity was restricted to Sv39. The failure
   remained, excluding prefetch as the initiating event.
5. RAS state was flushed on architectural context changes. The failure remained
   in the same form, excluding the RAS as the immediate target source.
6. Cycle-level fetch tracing was added around core PC, privilege, raw predictor
   output, applied redirect, RAS state, carousel/ingress state, translation
   slots, L1I requests, and L2 issue.
7. The trace exposed the partial-tag BTB collision and the exact four-cycle
   progression from lookup to applied redirect.
8. Predictor redirects were disabled in M-mode as a containment measure. A
   fresh source-matched build was run from reset because a Verilator checkpoint
   is tied to its generated model and cannot qualify changed RTL.

Two workflow traps mattered:

- A resume must use the exact simulator that created the checkpoint. A rebuilt
  model either cannot deserialize the checkpoint or is not evidence for the
  new RTL.
- One attempted managed resume selected a stale simulator artifact. Its repeat
  of the old fatal was not a failed test of the workaround. The qualifying run
  was rebuilt and started from reset.

The smaller `sim-opensbi-3p` harness was also not a replacement qualification
path: one attempt used a mismatched FDT placement, and a corrected attempt
reached an unrelated simple-fabric burst limitation. Neither result bears on
this RCA.

## Changes made

### M-mode redirect containment

`rtl/core/rv64_top_3p.v` now derives an effective prediction:

```text
bp_redirects_enabled              = privilege != M
bp_prediction_taken_effective     = enabled && raw_prediction_taken
bp_target_mispredict_effective    = enabled && raw_target_mispredict
```

The effective taken bit drives both the fetch redirect and the per-lane
prediction metadata consumed by branch resolution. Gating only the redirect
would be wrong: the backend would believe the instruction was predicted taken
and could suppress the architectural taken-branch correction. The target-
mispredict redirect is gated for the same consistency reason.

The raw predictor still looks up and trains in M-mode. This is intentionally a
small workaround, not context isolation. M-mode training can still perturb
S-mode prediction and must be addressed by the permanent fix.

### RAS context handling

`rtl/core/exec/bp/bp.v` and `rtl/core/exec/bp/ras.v` now distinguish:

- architectural context flush: clear stack, count, and pending-call state;
- ordinary squash: clear only pending speculative-call accounting.

`rtl/core/rv64_top_3p.v` supplies `control_flush` as the architectural RAS
flush.

### L1I speculative containment

The following are now restricted to translated Sv39 execution:

- branch-side L1I hints;
- RAS-directed side fetches;
- next-line prefetch generation; and
- retained L1I prefetch age/activity.

Leaving M-mode demand fetch enabled is required. Only speculative fetch-ahead
activity is suppressed.

### Verification and tracing

`tb/tb_top_axi_3p.sv` counts applied predictor redirects and asserts that the
M-mode directed test applies none. Expected architectural corrections were
updated because M-mode controls are now treated as not predicted.

`tb/verilator_4h_checkpoint_main.cpp` gained bounded fetch-path tracing used to
correlate predictor, RAS, fetch storage, translation, L1I, and L2 state around a
saved checkpoint.

`doc/TODO.md` records the requirement to replace the workaround with context-
safe target speculation and a directed trap/return alias regression.

## Validation

Focused RTL regressions passed:

```text
make -j8 sim-exec-bp sim-bp-context sim-fetch-3w
make -j8 sim-top-axi-3p-bp
git diff --check
```

The qualifying Linux command was:

```text
run/run run/cfg/linux-l1-zbb-regression-1h-ddr3.cfg --rebuild
```

Run `linux-l1-zbb-regression-1h-ddr3-20260809T033043Z` passed from reset:

| Result | Value |
|---|---:|
| Historical fatal | 156,660,600 cycles |
| `/init` launch | between 156M and 157M cycles |
| BusyBox init marker | between 158M and 159M cycles |
| Interactive `openrv64# ` prompt | 163,597,629 cycles |
| Hart 0 retired | 72,031,417 instructions |
| Hart 0 ICX requests | 13,730,018 |
| Memory reads / writes | 1,142,292 / 648,778 |
| Verilator result | clean `$finish`, exit 0, `validation=pass` |
| Wall time | 11,186.178 seconds, one thread |

This proves that the containment avoids the reproduced single-hart failure and
permits this Linux image to boot. It does not prove the target predictor is
context-safe, and it is not 2H/4H validation.

## Permanent fix requirements

Before M-mode target redirects are re-enabled:

1. Make BTB identity context-safe. At minimum, cover the omitted high PC bits
   and privilege/effective VM mode. ASID or an address-space generation should
   be considered for isolation and security, not merely functional recovery.
2. Stop training return targets into the general indirect BTB, or record the
   control-transfer type. This removes the exact return-to-call collision but
   does not replace complete context identity.
3. Define RAS lifetime across traps, returns, SATP writes, and address-space
   changes. The current architectural flush is safe but conservative.
4. Make speculative instruction faults and stale-context responses squashable
   by speculation epoch. A wrong-path target must not become an architectural
   fault or a platform-fatal transaction.
5. Add a physical-range/PMP defense before L2 so an invalid speculative M-mode
   target cannot escape the core even if predictor context handling regresses.
6. Add a directed regression with S-mode and M-mode control PCs sharing
   `PC[25:2]`, including an S-mode return followed by an M-mode indirect call.
   Check the predicted target source, privilege transition, cancellation, and
   absence of any out-of-range ICX/L2 request.
7. Rerun fresh 1H, 2H, and 4H timed-DDR3 Linux boots after the permanent fix;
   checkpoint replays alone are insufficient after RTL changes.

