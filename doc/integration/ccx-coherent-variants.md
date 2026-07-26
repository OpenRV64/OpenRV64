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
- [ ] Execute LR/SC and AMOs at the coherent home.
- [ ] Add one reservation record per hart and define the initial reservation
  granule as one 64-byte line.
- [ ] Clear matching reservations on conflicting writes, AMOs, successful
  SC, and per-hart reset.
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
- [ ] LR/SC interference and every implemented AMO width/operation.
- [ ] Acquire/release message-passing and full-fence litmus tests.
- [ ] Per-hart reset during an otherwise idle system and during queued traffic.
- [ ] Four real cores through OpenSBI and timed DDR3.

## Four-L1D integration test

`tb/tb_ccx_4h_l1d_directory_l2.sv` instantiates:

```text
four LSU-side request agents
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

This is not yet a four-core test.  The four agents drive the LSU-side contract
below the core memory channel; they do not instantiate decode, translation, or
the LSQ.  The backing store is deterministic, not timed DDR3.  The probe
adapter is testbench-only because the production L1D and L1I still need
independent probe queues.

The current sequence deliberately has the writing hart absent from the
directory sharer set.  A recorded requester can otherwise be self-probed while
its posted store is still buffered, but the current L1D refuses invalidation
until that store drains.  That circular wait is a real integration defect, not
a testbench artifact.  Fix the private-cache probe queue and matching
store/refill arbitration before enabling arbitrary four-core traffic.
