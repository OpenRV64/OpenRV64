# Coherent CCX variants

## Scope and repository boundary

The existing one-hart and generated transport-only complex remain unchanged.
The coherent work is additive:

```text
rtl/complex/2h/ccx.v       fixed two-hart variant
rtl/complex/4h/ccx.v       fixed four-hart variant
rtl/complex/coherent/      implementation shared by two and four harts
```

The first implementation includes the probe control plane and a separate
non-inclusive coherent protocol frontend.  The selected design uses an
independently tagged snoop-filter directory in front of the existing L2.
See `ccx-coherent-protocol.md` for the frontend/L2 boundary.

The one-hart implementation does not use these modules.  The shared coherent
modules reject hart counts other than two and four.

## Current invariants

- Directory residency is independent of L2 residency.
- A directory victim with recorded sharers is not reused until every recorded
  I-cache and D-cache copy acknowledges invalidation.
- A directory bit is removed only after the corresponding probe ACK.
- Probe identity, command, cache selection, and line address remain stable
  until each target accepts the probe.
- Probe addresses are aligned to the 64-byte coherence granule.
- The initial tracker permits one active invalidation.
- The coherent frontend is the home and currently serializes all traffic.
- A private sharer is recorded before its successful fill response is exposed.
- I-cache and D-cache sharers are distinct.
- Private lines remain clean; cross-hart data fetch is not yet legal.

## Cleanup and implementation ledger

Items below are deliberately not hidden behind compatibility behavior.

### Existing baseline

- [ ] Diagnose the `tb_core_complex.sv` full-line data mismatch.  It reproduces
  in the existing one-hart AXI and four-hart Wishbone targets, so it is not
  evidence against the new coherent control plane.
- [ ] Rename or clearly label the existing `wrapper_nh.v` complex as
  transport-only once downstream users have migrated.
- [ ] Keep the existing one-hart regressions as the compatibility baseline.

### Private-cache endpoints

- [x] Prove a testbench probe adapter against four real L1D invalidation
  ports; it withholds each ACK until the matching L1D accepts invalidation.
- [ ] Add an independent bounded probe queue to each L1I and L1D endpoint.
- [ ] Invalidate resident matching lines and ACK absent lines.
- [ ] Poison or cancel a matching refill before acknowledging its probe.
- [ ] Remove the current dependency between invalidation acceptance and an
  otherwise idle demand/store path.
- [ ] Break the circular wait in which a probe forces the target L1D store
  buffer to drain through a coherence home that is waiting for that probe.
  Until then, simultaneous buffered writers are not a legal stress mode.
- [ ] Define clean-eviction notification only if measurements show stale
  directory bits produce material probe traffic.

### Coherent L2 and home

- [x] Separate the coherent frontend from the non-inclusive L2 backend.
- [x] Add an independently tagged I/D snoop-filter directory.
- [x] Invalidate recorded private copies before directory replacement.
- [ ] Replace or qualify the current combinational snoop-filter arrays with a
  synchronous SRAM-friendly lookup pipeline before making frequency or area
  claims.
- [ ] Lock down the current L2 write-response coherence point with assertions
  and directed tests.
- [x] Integrate `coherent_protocol.v` between the line crossbar and
  `l2_native.v` in the focused four-L1D testbench.
- [ ] Move that integration into the production 2h/4h complex wrappers.
- [ ] Add per-hart response queues so one stalled hart cannot block unrelated
  responses.
- [ ] Replace global serialization with bounded per-line home transactions
  after the one-transaction invariants are proven.
- [ ] Keep MMIO/device requests outside L2 allocation and directory updates.
- [ ] Allow PTW requests to allocate in L2 without becoming private sharers.
- [ ] Remove the earlier L2-indexed directory-control prototype after the fixed
  2h/4h wrappers use the independently tagged frontend.

### Writes, atomics, and ordering

- [ ] Preserve LR, SC, AMO operation, width, and `aq`/`rl` from the core
  through the private-cache endpoint.
- [ ] Mark or explicitly encode a direct architectural LR at the L1D
  boundary.  `openrv64_exec_lsu_rv64a` currently marks AMO read halves and SC
  writes, but not a standalone LR, so direct LR/SC is not integrated even
  though the home protocol itself supports both operations.
- [x] Translate the existing L1D atomic marker into LR for the marked read and
  SC for the marked write while keeping the fabric lock signal low.
- [x] Execute LR/SC reservation validation at the coherent home.
- [ ] Move AMO arithmetic to the home, or carry the original AMO opcode to it.
  The compatibility path still computes the AMO result in the local RV64A
  block before issuing SC.
- [x] Add one reservation record per hart and define the initial reservation
  granule as one 64-byte line.
- [x] Clear matching reservations on conflicting writes and consume the
  requester's reservation on every SC attempt.
- [ ] Clear reservations on per-hart reset/disable without resetting unrelated
  harts.
- [ ] Return failed-SC status to the architectural LSU and retry decomposed
  AMOs.  The current L1D drops `ccx_resp_sc_success`, so arbitrary contended
  AMOs are not correct.
- [ ] If dirty private ownership is ever added, implement data-bearing
  `READ_SHARED` and `READ_INVALIDATE` probes before enabling it.
- [ ] Replace globally draining L2 fences with per-hart outstanding-operation
  accounting.
- [ ] Connect architectural `FENCE` to actual L1D store and request drains.
- [ ] Keep `FENCE.I` local; perform remote instruction synchronization through
  software notification and remote `FENCE.I`.

### Reset, SoC, and software

- [ ] Define a per-hart reset/online handshake that clears directory bits only
  after the corresponding private caches can no longer return hits.
- [ ] Instantiate four cores with fixed `mhartid` values zero through three.
- [ ] Parameterize platform CLINT and PLIC integration for the selected hart
  count.
- [ ] Replace the single-hart OpenSBI device tree with generated 1/2/4-hart
  descriptions.
- [ ] Stop forcing hart zero in the OpenSBI trampoline.
- [ ] Add secondary-hart release and boot synchronization.
- [ ] Reuse the AXI and timed-DDR3 path below the new coherent L2.

### Verification gates

- [ ] Probe/refill race with ACK withheld until the refill cannot install.
- [x] Sequential read/read/write/read visibility through four real L1Ds, the
  directory frontend, and the shared L2.
- [ ] Same-line writes from two harts, including disjoint byte lanes.
- [x] Non-inclusive directory eviction with mixed I-cache and D-cache sharers.
- [x] Directed LR/SC success, repeated-SC failure, and reservation loss after
  an intervening write.
- [x] Every implemented 64-bit AMO arithmetic operation through four local
  RV64A engines under globally quiescent atomic phases.
- [ ] Contended LR/SC and AMOs, 32-bit AMOs, and failed-SC retry.
- [ ] Acquire/release message-passing and full-fence litmus tests.
- [ ] Per-hart reset during an otherwise idle system and during queued traffic.
- [ ] Four real cores through OpenSBI and timed DDR3.

## Four-L1D integration test

`tb/tb_ccx_4h_l1d_directory_l2.sv` instantiates:

```text
four LSU-side request agents plus four local RV64A engines
  -> four openrv64_l1d_ccx instances
  -> openrv64_ccx_line_crossbar
  -> openrv64_ccx_coherent_protocol
  -> openrv64_ccx_l2_native
  -> fixed-latency line-memory model
```

Run it with:

```sh
make sim-ccx-4h-l1d-directory-l2
```

The directed sequence proves:

- harts 0 and 1 can retain clean copies of one line while harts 2 and 3 use
  unrelated lines through the same L2;
- a repeat access hits in private L1D;
- a write from a non-sharer invalidates exactly the recorded sharers;
- the directory does not forward the write to L2 before both real L1D
  invalidation handshakes complete;
- a probed hart reloads the new value from L2 without a backing-memory read;
  and
- a later sharer set containing harts 0 and 3 is also invalidated correctly.

The randomized phase then runs 2,048 rounds by default: 8,192 ordinary
operations over an eight-page (32 KiB) window, including 2,048 stores, plus 64
64-bit AMOs rotating across all four harts.  Addresses, word lanes, payloads,
and AMO operations are varied from a deterministic xorshift seed; use
`+seed=<decimal>` with the compiled simulation to replay another stream.

Two independent scoreboards check the result:

- a tag scoreboard records every accepted LSU/L1D request and matches the
  normal or posted response by hart and tag, including read data; and
- a home-order scoreboard compares every L2 command/data beat with the write
  expected from that hart, applies byte strobes to reference memory in actual
  home acceptance order, and checks later home reads against that state.

The random round has four distinct lines and at most one buffered writer.
This is a correctness restriction, not a claim that the intended protocol
only supports one writer.  Multiple target store buffers can currently
deadlock because a probe forces a target buffer to drain through the same
serialized home that is waiting for the probe response.

AMOs are also globally quiescent in this test.  The existing local RV64A block
has already reduced an AMO to a marked read and marked write.  The L1D adapter
encodes those halves as LR and SC, the directory checks the reservation, and
the crossbar treats SC as a write-data-bearing command.  This proves the
compatibility path only.  It does not prove contended AMOs because failed-SC
status is not yet returned to or retried by the local AMO engine.

This is not yet a four-core test.  The four agents drive the LSU-side contract
below the core memory channel; they do not instantiate decode, translation, or
the LSQ.  The backing store is deterministic, not timed DDR3.  The probe
adapter is testbench-only because the production L1D and L1I still need
independent probe queues.

The home no longer probes a recorded write-through requester for its own
store; it retains that requester's clean D-cache sharer bit and invalidates
only the other recorded sharers.  The remaining cross-hart store-buffer/probe
cycle is a separate integration defect.  Fix the private-cache probe queue and
matching store/refill arbitration before enabling arbitrary four-core traffic.
