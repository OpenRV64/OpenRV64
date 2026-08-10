# L1D invalidate request-owner alias

## Status

The demonstrated failure is contained by a one-entry invalidate transaction
arbiter in `openrv64_l1d_icx`.  A directed collision test fails on the old RTL
and passes with the arbiter.  Full Linux 2-hart and 4-hart validation is still
required.

This is a serious architectural warning.  The implementation bug is local, but
the cause is not merely a missing condition: two independently timed operations
were collapsed onto an unowned request/completion channel.  The coherent probe
endpoint had a probe ID, a saved address, and a pending bit, while the L1D
wrapper discarded that identity at the point where it merged the probe with
local atomic cache maintenance.

The containment fix does not constitute a complete redesign of the private
cache coherence endpoint.

## Failure

The observed Linux failure was a stuck ticket lock at physical address
`0x8090efe4`, in cache line `0x8090efc0`.  Hart 1 legitimately obtained ticket
`0x3b`, advanced the L2 copy from `0x003b003b` to `0x003c003b`, and later hart 0
also obtained ticket `0x3b` from a stale private-L1 copy.  Both holders
eventually released the same ticket.  The owner advanced past ticket `0x3c`,
leaving its legitimate holder unable to enter the critical section.

The source run is:

```text
run/log/linux-l1-zbb-regression-2h-ddr3-20260810T024433Z/
```

The decisive replay sequence was:

| Cycle | Event |
|---:|---|
| 51,314,662 | Hart 0 launches a local atomic self-invalidate for the unrelated line containing `0x80a1be90`.  The synchronous L1 tag lookup becomes pending. |
| 51,314,663 | An external probe for `0x8090efc0` becomes valid.  No new tag lookup launches, but the generic L1's delayed `ready` for the local invalidate is high. |
| 51,314,663 | The L1D wrapper routes that old `ready` to the currently selected external source.  The probe endpoint treats the external invalidate as complete and generates its acknowledgement. |
| 51,604,158 | Hart 1 reads `0x003b003b` and obtains ticket `0x3b`. |
| 51,604,170 | L2 accepts hart 1's atomic write of `0x003c003b`. |
| 51,607,393 | Hart 0's atomic read is answered from its stale L1 copy as `0x003b003b`. |
| 51,607,418 | Hart 0 retires a second acquisition of ticket `0x3b`. |

The critical trace sample is:

```text
cycle=51314662 ext_valid=0 ext_ready=0 launch=1 probe=0 tag_read_fire=1 tag_read_set=58
cycle=51314663 ext_valid=1 ext_ready=1 launch=0 probe=1 tag_read_fire=0
```

`launch=0` and `tag_read_fire=0` prove that the external line was not presented
to the tag array.  `ext_ready=1` nevertheless completed it.  This is not a late
invalidate, a slow invalidate, or a Linux ordering error.  It is a fabricated
completion.

## Root cause

The old L1D wrapper formed one generic-L1 request combinationally:

```systemverilog
l1_invalidate_valid = invalidate_valid_i || lock_invalidate_request;
l1_invalidate_addr  = invalidate_valid_i ? invalidate_addr_i : req_addr_i;
```

External invalidation had instantaneous priority.  Completion was also
combinationally routed from the generic L1's `l1_invalidate_ready`.

That construction is valid only if `ready` is same-cycle acceptance of the
currently selected request.  It is not.  With synchronous tag lookup enabled,
the generic L1 captures an invalidate address, reads tags, and asserts `ready`
on a later cycle through `sync_invalidate_probe_q`.  The generic L1 correctly
retains the address it launched.  The outer L1D wrapper did not retain which
source owned that operation.

The failure therefore required this one-cycle alignment:

1. local atomic invalidation launches;
2. its delayed completion becomes ready;
3. external valid changes the combinational source selection on that cycle;
4. completion is credited to the external source.

The probe endpoint then converted the false completion into a real coherence
acknowledgement.  L2 was permitted to modify the line because it had been told
that hart 0 could no longer observe the old copy.  Hart 0 still had that copy.

## Containment fix

`openrv64_l1d_icx` now contains a one-entry transaction register holding:

- valid;
- owner: external probe or local atomic maintenance;
- full-cache versus targeted operation; and
- invalidate address.

Selection occurs only while the transaction register is empty.  The selected
owner and payload remain fixed until the generic L1 returns completion.
Completion is routed exclusively to the captured owner.

Targeted external probes retain priority when the arbiter is idle and remain
admissible during unrelated misses.  Full-cache maintenance retains its prior
global-quiescence condition.  A local atomic invalidate wins over a coincident
full-cache invalidate so neither operation waits for a quiescence condition
which the other operation prevents.

The arbiter deliberately does not turn over to a new request on the completion
edge.  The extra cycle is conservative and removes another edge-sensitive
ownership case.  Invalidation throughput is not currently important enough to
justify bypass logic here.

The required invariants are now structural:

1. an external `ready` is possible only while an external transaction owns the
   register;
2. local completion cannot be observed by the external probe endpoint;
3. address, operation kind, and owner do not change while the generic L1
   operation is pending; and
4. every completed external transaction was separately captured and launched.

## Directed regression

`tb/tb_l1d_invalidate_arbiter.sv` reproduces the exact request-owner collision:

1. install a target line in L1D;
2. begin a locked store to an unrelated line, causing local self-invalidation;
3. wait until the generic L1 has the local synchronous invalidate pending;
4. assert an external invalidate for the target line on its completion cycle;
5. require the external operation to receive a separate completion; and
6. load the target again and require a lower-level read, proving eviction.

The pre-fix result is:

```text
FATAL: external invalidate consumed completion of local invalidate
```

The post-fix result is:

```text
PASS: external invalidate cannot consume local invalidate completion
```

Focused post-fix regressions also pass:

- synchronous generic-L1 tags and invalidate probes;
- L1D prefetch, demand MSHRs, store ordering, and store buffering;
- LSU atomic sequencing; and
- the 4-hart L1D-directory-L2 stress test: 2,048 rounds, 8,192 ordinary
  operations, and 128 atomics.

The source-matched Verilator Linux model rebuilt successfully.  Fresh timed
DDR3 validation is in progress in:

```text
run/log/linux-l1-zbb-regression-2h-ddr3-20260810T133244Z/
run/log/linux-l1-zbb-regression-4h-ddr3-20260810T133254Z/
```

These runs are not recorded as passes until they produce the shell marker,
suite PASS marker, and clean simulator exit.

The relevant generic-L1 and L1D transaction signals are exported through their
simulation debug stubs.  The checkpoint tracer no longer reaches directly into
generated generic-L1 implementation members for this evidence.

## Architectural assessment

The blunt conclusion is that the coherence endpoint boundary has outgrown the
legacy invalidation interface.  The design has acquired asynchronous probes,
local atomic maintenance, detached misses, prefetch state, write-through
traffic, and delayed synchronous tag lookup.  A single untagged
`valid/address/ready` tuple is too weak unless all arbitration and ownership are
made explicit immediately above it.

This bug does not prove that the entire cache hierarchy is unsound.  It does
prove that correctness was depending on a timing coincidence at a boundary
which now has multiple independent actors.  Random lock traffic did not expose
the exact one-cycle collision.  Linux did.  More traffic alone is not an
adequate verification strategy for this class of defect.

### Targeted adjacent-path audit

- `openrv64_icx_l1d_probe_endpoint` already captures probe ID and line address,
  holds invalidate valid until completion, and does not manufacture an ACK on
  timeout.  The identity loss occurred below it in the L1D local/external merge.
- The generic L1 synchronous invalidate path captures its address, set, tag, and
  valid-way snapshot before returning delayed completion.  Its contract was
  violated by its caller; it did not independently drop the request.
- The L1I wrapper has one payload-less, idempotent full-cache invalidation
  operation.  Its pulse and pending-bit sources can collapse without selecting
  different addresses or response owners, so it does not have this failure
  mode.
- The ICX outbound command arbiter retains a registered client grant and routes
  `ready` only to that captured client.
- The PTW's merged fence/walk request is selected by mutually exclusive state
  conditions; it does not rely on a delayed completion to identify the current
  request source.
- The L2 probe tracker retains probe identity and per-hart issue/ack masks.

This was a targeted invalidate/probe and adjacent-arbiter audit, not a proof
that every ready/valid merge in the repository is correct.

## Required follow-up

The one-entry arbiter is acceptable containment.  The next architecture work
should not be another local condition on the mux.

1. Define a private-cache maintenance transaction type with explicit source,
   operation, address, and transaction identity.
2. Give the L1D coherence side a dedicated probe request queue/FSM and response
   queue.  Its lifecycle must cover accept, conflict detection, poison/replay,
   tag revocation, acknowledgement, and error/timeout without losing identity.
3. State and verify transaction-conservation properties: every accepted probe
   produces exactly one matching cache operation and at most one matching
   response; no response exists without a completed operation.
4. Add bounded-progress properties for probes colliding with atomic requests,
   store-buffer backpressure, fills, demand MSHRs, and response backpressure.
5. Reuse a registered-owner arbitration primitive for any multi-source channel
   whose completion is not same-cycle request acceptance.
6. Add collision tests which sweep an external probe across every cycle of
   local invalidate launch, tag read, completion, atomic admission, and refill.
7. Keep diagnostics behind stable debug stubs.  Generated RTL member names are
   not an interface and must not become part of the verification contract.

Linux 2-hart and 4-hart boots are necessary regression evidence after this
change, but they cannot close the architectural issue.  Closure requires the
transaction properties and collision coverage above, or the dedicated endpoint
redesign which makes those properties straightforward.
