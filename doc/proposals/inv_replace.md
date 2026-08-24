# Invalidate-and-replace coherence proposal

Status: experimental proposal; not accepted for implementation

This document records a possible data-bearing coherence operation for the
clean, write-through private L1D hierarchy.  The idea should remain dormant
until the current Linux, cache, translation, and physical-design work is less
congested.  It is intended to support a bounded A/B experiment, not establish
a new baseline protocol.

## Summary

An L2-originated coherence invalidation may carry the authoritative updated
512-bit cache line:

```text
INV_REPLACE(probe_id, line_address, updated_line)
```

For a resident matching line, the receiving L1D invalidates the old version
and installs the supplied version as one coherence operation.  There is no
intervening demand refill and no post-probe interval in which the LSU may
access the old generation.  After completion, the line remains valid, clean,
and shared.

This is functionally a write-update operation even though the old line is
invalidated as part of replacement.  It does not introduce Modified private
ownership or make an L1 authoritative.

## Motivation

The current clean Shared/Invalid protocol sends address-only invalidations to
remote D-cache sharers before a coherent write reaches L2.  A hart which soon
uses the invalidated line must then issue a demand read and fetch the same
updated 64-byte line back from the shared hierarchy.

That sequence is particularly unattractive for contended LR/SC locks and
other producer/consumer lines: the invalidation is often followed immediately
by an L2 refill.  Supplying the updated line with the coherence operation may
replace the invalidate/request/refill sequence with one pushed line transfer
and remove an L2-hit round trip.

The tradeoff is that every targeted sharer receives 64 bytes whether or not it
will use the new version.  This may help highly contended lines and waste
bandwidth on false sharing or inactive sharers.  The proposal therefore needs
measurement rather than adoption by inspection.

## Required coherence ordering

The intended write sequence is:

1. L2 obtains the authoritative old line and merges the incoming byte-masked
   write, producing the complete updated line.
2. L2, directly or through the coherence controller, sends `INV_REPLACE` to
   every targeted remote D-cache sharer.
3. Each target atomically revokes the old generation, installs the supplied
   line, clears any matching LR reservation, and acknowledges only after its
   tag/data update is committed.
4. The coherent write is reported complete only after every required target
   has acknowledged replacement.

Loads accepted by a target before it accepts the replacement may observe the
old version.  Loads accepted after replacement acceptance must not observe the
old version.  Delaying global write completion until all acknowledgements
orders the former loads before the write and prevents a stale private hit
after the writer has observed completion.

The current coherent frontend invalidates sharers before forwarding a partial
write to L2, and the current L2 write response carries no replacement line.
An experiment must therefore change the sequencing.  L2 could expose its
post-merge line to the coherence controller, while the controller withholds
the upstream write response until replacement acknowledgements complete.  It
is not sufficient to attach the incoming byte-masked store payload to the
probe; bytes outside the mask must come from the authoritative L2 line.

## Receiving L1D contract

Replacement must be an L1D coherence transaction, not a loose invalidate
followed by the ordinary fill interface.  The endpoint must:

- capture the probe identity, physical line address, and complete line data;
- stop post-probe accesses to the old line generation;
- clear the matching local LR reservation on probe acceptance;
- obsolete or consume any older matching demand/prefetch response by its
  transaction identity;
- discard stale matching fill-buffer and prefetch state;
- merge any coherently younger local same-line posted-store overlay onto the
  supplied base line, so replacement cannot erase locally visible stores;
- arbitrate the single L1D data-SRAM write port against fills and local stores;
- install the final data and mark the line valid and clean/shared; and
- issue the probe acknowledgement only after the tag/data update commits.

Matching demand waiters may be satisfied directly from the supplied line if
their ordering and store overlays are preserved.  Reissuing them to L2 would
retain correctness but discard much of the proposed latency benefit.

A pre-probe load response which has already captured the old data remains an
operation ordered before the replacement.  Replacement must not mutate that
held response, but the L1D must not create a new old-generation response after
accepting the probe.

## Directory behavior

For a successful resident replacement, the target remains a D-cache sharer.
The directory must not clear its sharer bit as it does for the current
address-only invalidation.

The current snoop-filter directory is conservative: a recorded sharer may have
silently evicted the line.  The experiment must choose and measure one of two
miss policies:

- **Hit-only replacement:** return an explicit miss acknowledgement, discard
  the payload, and clear the stale sharer bit.  This avoids unsolicited
  allocation and cache pollution.
- **Allocate on replacement:** install the supplied line even on a probe miss,
  possibly evicting another private line.  The target becomes a real sharer
  again, but update traffic can perturb unrelated working sets.

Hit-only replacement is the safer initial experiment.  A plain `ACK` is not
enough if the home needs to distinguish a retained sharer from a stale
directory bit; the response requires a hit/miss indication or distinct
response kind.

Directory-victim invalidation remains a separate destructive operation.  A
directory entry cannot be reclaimed if its former sharers are immediately
given replacement copies while the home forgets how to find them.  The
protocol therefore still needs both operations:

```text
INV          // revoke and remove the sharer
INV_REPLACE  // revoke the old version and retain the updated sharer
```

Ordinary coherent data writes target D-cache sharers.  Instruction-cache
visibility continues to use the existing local and remote `FENCE.I` contract;
this proposal does not silently make ordinary stores update L1I.

## Transport shape

The logical probe contains a full 512-bit line, but the physical implementation
should not add one 512-bit payload lane per hart.  For four harts that would
create 2,048 data wires before counting ordinary responses and writeback.

A more credible transport is one shared 512-bit replacement payload with a
target mask and probe ID.  The payload may be multicast while held stable or
sent once per target.  Either form must retain independently reserved probe
ingress, acknowledgement, and forward-progress capacity; sharing physical
wires must not reintroduce demand/probe deadlock.

The extra transfer is 64 bytes per actual target.  Comparing that cost with
avoided demand refills is part of the experiment, not an assumption.

## Proposed experiment

Build source-matched protocol modes:

```text
INV_REPLACE_ENABLE=0  // current invalidate and later demand refill
INV_REPLACE_ENABLE=1  // data-bearing replacement on coherent writes
```

Start with focused tests covering:

- full and partial writes to one and multiple sharers;
- replacement hit and stale-directory miss;
- a matching younger posted store in the target L1D;
- simultaneous matching demand-fill and prefetch responses;
- held pre-probe load responses;
- replacement under data-SRAM and response backpressure;
- LR reservation loss and failed-SC restart;
- multiple replacement targets with delayed acknowledgements;
- directory-victim `INV` remaining destructive; and
- L2/write errors without premature global completion.

Then compare the existing four-hart, four-lock `lock_walk` workload using the
same source, image, timed-DDR3 configuration, and lock-line placement.  Linux
four-hart boot and the user/futex/pthread suite are required functional
regressions, but they are too broad to diagnose the mechanism by themselves.
CoreMark is largely irrelevant because it does not exercise cross-hart data
coherence.

At minimum, collect:

- replacement probes and target count;
- replacement payload bytes;
- target hits, misses, and allocations;
- replacements used before the next replacement, invalidation, or eviction;
- matching local-store overlay conflicts;
- demand L2 reads avoided after replacement;
- probe acceptance and acknowledgement latency;
- probe/data-port arbitration stalls;
- lock-walk cycles, acquisitions per kilocycle, SC failures, probes, and
  per-hart skew; and
- aggregate Linux cycles only after functional completion is established.

The experiment is favorable only if it preserves coherence and forward
progress, reduces useful-work latency on contended sharing, and does not turn
full-line update traffic or SRAM-port contention into a larger regression.
RTL simulation is insufficient for acceptance: any retained design also
needs mapped cost and routed timing evidence for the new 512-bit path.

## Open questions

- Should a probe miss allocate the line or prune the stale sharer?
- Is replacement always enabled, or selected by line history such as repeated
  invalidation followed by prompt reload?
- Does L2 originate the operation directly, or return the merged line to a
  coherence controller which owns probe sequencing?
- Can one shared 512-bit half-duplex data path carry fills, writeback, and
  replacement traffic without violating probe forward progress?
- Can matching demand waiters consume replacement data directly without
  complicating store-overlay ordering?
- Is the mechanism still attractive if a later private cache becomes
  write-back and introduces dirty ownership?

No answer is selected here.  The proposal is intentionally parked pending a
focused experiment and available implementation bandwidth.
