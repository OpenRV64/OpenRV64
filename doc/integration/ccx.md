# Core-complex hart integration

This document defines what an OpenRV64 hart and its private caches must provide
to integrate with the shared core complex.  It covers the northbound coherent
boundary.  AXI4 and WISHBONE remain external transports below the complex and
are not hart-facing protocols.

The native northbound CCX data interface is fixed at 512 bits: one transfer
beat is exactly one 64-byte cache line.  A requester may issue a burst covering
multiple consecutive cache lines.  Such a burst remains a sequence of 512-bit
line beats; CCX never packs multiple cache lines into one beat.  Consequently,
the native CCX line size is fixed at 64 bytes rather than parameterized
independently from the interface width.

The current generated core complex is correct for direct, uncached hart
requests.  It is not yet coherent with multiple enabled private L1 caches.
Adding an invalidation wire alone is not sufficient: coherent integration also
requires explicit operation intent, probe acknowledgement, transient-state
handling, atomic execution at the home agent, and real memory-barrier
completion.

## Current limitations

The existing generic core memory port exports only `valid`, `ready`, `write`,
address, write data, byte strobes, read data, and error.  It has no transaction
ID, access size, requester type, memory attributes, or ordering information.
Consequently, `rtl/complex/protocol/hart_legacy_adapter.v` can emit only:

- `READ` or `WRITE`;
- `kind=LEGACY`;
- `order=NONE`;
- a constant integration-selected attribute; and
- an eight-byte transfer.

That adapter is a compatibility and bring-up seam, not the final coherent hart
endpoint.  Its 64-bit scalar channel does not implement the native 512-bit
cache-line contract.

Other current restrictions are:

- `rtl/core/exec/lsu/rv64-a.v` still keeps LR/SC reservations inside the hart.
  AMOs retain the local read/compute/write implementation but now mark both
  memory phases with `ccx_req_lock`.  The shared L2 can exclude other requests
  from the marked read through the matching marked write.  This remains a
  one-hart bring-up mechanism, not the final atomic protocol.
- The decoder accepts RV64A `aq` and `rl` bits, but the core currently discards
  them because the legacy memory path is blocking and strictly ordered.
- `rtl/cache/l1/l1.v` is physically tagged, hit-pipelined, write-through, and
  no-write-allocate.  Its separate lookup/physical address inputs allow VIPT
  L1I operation; L1D ties them together.  Resident reads sustain one request
  and response per cycle; misses and uncached accesses serialize the
  lower-memory port.  Tagged cacheable L1D stores may instead enter an ordered
  byte-masked line FIFO.  Back-invalidation drains accepted lookups, responses,
  and that store FIFO before modifying tags.
- L1I fill/prefetch slots and L1D fill/store buffers default to eight
  cachelines.  Their depths are parameterized.  The fill slots do not yet make
  the private caches nonblocking: each demand backend still has one active CCX
  miss and lacks transaction-ID-indexed MSHRs.
- The shared L2 accepts `READ`, `WRITE`, and a conservatively serialized
  `FENCE`.  It implements the temporary marked read/write exclusion, but LR,
  SC, and explicit AMO operations still fail.  It does not track private-cache
  sharers or emit probes.
- The three-pipe core and private caches expose the native 512-bit CCX
  interface, while the current L2 northbound controller remains the legacy
  64-bit command interface.  The production native-line-to-L2 adapter is not
  yet present; current integrated native tests terminate CCX in a memory
  model, and L2 lock behavior is tested separately.
- `HART_ID` now reaches both native CCX identity and the `mhartid` CSR on the
  three-pipe top.  The generated multi-hart complex still uses legacy scalar
  transport endpoints rather than instantiated native core tops.

## Required hart request contract

A native hart endpoint must preserve the following fields through translation,
PMP checking, and private-cache lookup:

| Field | Meaning |
| --- | --- |
| `valid/ready` | Decoupled request acceptance.  Payload remains stable until accepted. |
| `hart_id` | Physical source hart, matching the hart's `mhartid`. |
| `source_id` | At least instruction cache, data cache, or PTW. |
| `txn_id` | Requester transaction identity, not reused until its response is drained. |
| `op` | Read, write, LR, SC, AMO function, or fence. |
| `lock` | Transitional one-hart AMO exclusion marker; asserted on both decomposed phases. |
| `order` | None, acquire, release, or acquire-release. |
| `attr` | Per-request cacheable, device, idempotent, and executable attributes. |
| `size` | Sub-line access size for atomics and uncached operations; cache-line transfers imply 64 bytes. |
| `addr` | Physical start address.  Cache-line operations are 64-byte aligned. |
| `burst_len` | Number of additional consecutive cache lines; zero requests one line. |
| `wdata/wstrb` | One 512-bit cache-line beat and 64 byte enables. |

The response must return `hart_id`, `source_id` or an equivalent uniquely
routed identity, `txn_id`, one 512-bit cache-line data beat, `beat_index`,
`last`, error, and SC success.

The existing CCX response contains only `hart_id` and `txn_id`.  That is
sufficient only if all I-cache, D-cache, and PTW requests within one hart share
one transaction-ID allocator.  If those endpoints allocate tags independently,
CCX must add `source_id` to both requests and responses.

## Cache-line transport and bursts

The interface above CCX is cache-line based.  Scalar execution loads and stores
terminate at the private-cache or hart-endpoint boundary; they are not expanded
into a 64-bit CCX datapath.  A cacheable miss, refill, eviction, intervention,
or prefetch moves one complete 64-byte line on each accepted CCX beat.

The native burst contract is:

- `burst_len=0` requests one cache line;
- `burst_len=N` requests `N+1` consecutive cache lines beginning at `addr`;
- line `i` has address `addr + 64*i`;
- each request-data or response-data beat carries exactly one line;
- response beats for one transaction are returned in increasing line-address
  order and identify the final beat with `last`;
- backpressure applies independently to every line beat; and
- different tagged bursts may be interleaved, but beats remain identifiable by
  `hart_id`, `source_id`, and `txn_id`.

A burst is not an atomic multi-line operation and does not reserve or lock all
of its lines.  The L2 expands it into individual home operations so each line
is independently looked up, merged, probed, ordered, and faulted.  Arbitration
may occur between its line operations so a long burst cannot monopolize CCX.

All lines declared by one burst must be physically contiguous and use the same
operation, ordering mode, and PMA attributes.  The requester splits a burst
where translation is not physically contiguous or attributes change.  CCX is
not constrained by AXI's 4 KiB rule; the southbound adapter splits an external
AXI burst as necessary.

Read, refill, and prefetch operations consume no request-data beats and return
one 512-bit response beat per line.  Line writeback or other line writes supply
one 512-bit request-data beat per line with a corresponding 64-bit byte mask.
Atomics, fences, and side-effecting device operations require `burst_len=0`.
For a sub-line atomic or uncached access, `addr` and `size` select bytes within
the 512-bit beat and only those data lanes are meaningful.

The command and line-data channels must be independently backpressured.  An
implementation may accept a burst descriptor only when it has reserved enough
tracking state, but it must not require buffering the entire burst's data before
the first line can progress.

One outstanding transaction per hart is an acceptable first implementation;
that transaction may contain multiple cache-line beats when it is a burst.
When concurrency is enabled, the endpoint must additionally ensure that:

- canceled speculative reads are drained and their tags are not reused early;
- stores and atomics cannot be canceled after becoming globally visible;
- same-address load/store dependencies compare translated physical addresses,
  including aliases;
- response errors remain associated with the initiating instruction; and
- separate requester paths cannot reorder operations across a fence.

## Per-request physical memory attributes

Cacheability cannot be a constant property of a hart port.  The endpoint must
derive PMA attributes from the final physical address and attach them to every
request.

Every line in a burst must have the same attributes.  The endpoint must split
the request before a PMA boundary rather than applying the first line's
attributes to the rest of the burst.

Device and non-cacheable operations must:

- bypass private and shared-cache allocation;
- never join a cache-line fill or merge queue;
- not be speculated, combined, or replayed when that could repeat a side
  effect;
- use the required stronger ordering; and
- disable store-to-load forwarding unless the region explicitly permits it.

A posted device write is not implicitly a pre-barrier.  Software which relies
on all older writes reaching the device first must execute the required write
barrier before issuing it.  A later implementation may provide a CSR policy
which forces selected device writes to wait for the older-store drain, but that
is an optional stronger mode rather than the base ordering rule.  The current
RTL leaves device and non-cacheable writes blocking while this PMA and barrier
policy is not yet wired.

## Current posted-store contract

`openrv64_l1d_ccx` implements the first cacheable store buffer at the private
L1 boundary:

- `STORE_BUFFER_LINES` defaults to eight entries and is configurable from one
  through sixteen;
- every entry is one aligned 64-byte address, 512 data bits, and 64 byte
  enables;
- a scalar CPU store occupies its addressed lane without forcing L1 to read or
  merge the other bytes;
- FIFO order is retained and each drain is one CCX line write with `size=6`;
- `#LOCK`, uncached, and device operations are not posted in this revision;
- an external invalidation is acknowledged only after the FIFO becomes empty;
  and
- the separate ordered store-response channel carries the eventual CCX error.

The core bus has a matching tag FIFO.  The execution pipe may retire a posted
store when the bus accepts it, but it retains the LSU slot until the drain
response arrives.  A late CCX failure is therefore reported through the
existing asynchronous-store-fault path rather than silently discarded.  This
distinction is required: fast admission and precise synchronous fault delivery
cannot both be claimed after architectural retirement.  The current core has
eight LSU tags, matching the default eight-entry L1D FIFO, so one hart can hold
eight unacknowledged stores.  A deeper FIFO requires a larger tag namespace or
a separate deferred-fault metadata queue to exploit every entry from one hart.

PMP remains an access-permission check.  PMA describes the behavior of an
allowed physical target; one does not replace the other.

## Atomic execution and reservations

LR, SC, and AMOs must execute at the coherence home for the addressed granule,
which is initially the shared L2 controller.  The hart must send the original
operation rather than exposing an inferred sequence of reads and writes.

The home agent must provide the following behavior:

1. LR reads the value and establishes a reservation for the requesting hart.
2. SC occupies one position in the home order, tests the reservation, performs
   the store only on success, and returns explicit success status.
3. An AMO performs its read, calculation, and write as one indivisible home
   operation and returns the old value.
4. Conflicting writes, AMOs, successful SCs, and other implementation-defined
   reservation-loss events clear affected reservations.
5. A hart reset or removal clears that hart's reservation state.

A 64-byte L2-line reservation granule is a conservative initial choice.  It may
produce more failed SC operations than a word-sized granule, but it keeps
reservation invalidation aligned with the first coherence implementation.

Initially, atomics should bypass the private L1.  The home agent invalidates
all private copies, including a possibly stale copy in the requesting hart,
then performs the operation and returns its result.  A later ownership-based
L1 protocol may execute atomics while holding a line exclusively, but that is
not required for the first coherent version.

The atomic still uses the 512-bit CCX data path.  Its physical address and size
select the 32- or 64-bit operand lane, the returned old value occupies that
lane, and the remaining response-line bits have no architectural meaning.

### Current one-hart AMO bring-up

The implemented temporary path is narrower than the required final contract:

1. The hart retains its existing local AMO ALU and emits a `READ` with
   `ccx_req_lock=1`.
2. L1D invalidates its local copy, bypasses lookup/allocation, and forwards the
   marked sub-line request on the 512-bit native interface.
3. The home records the requesting hart and 64-byte line and excludes every
   request except a marked request from that hart to that line.
4. The hart computes the new value and emits the corresponding marked `WRITE`.
5. The home updates the line and releases the lock.  A read, refill,
   writeback, or bypass error also releases it.

The hart-local I/D command arbiter admits only D-cache commands while the
sequence is active.  Without that rule, a backpressured I-cache request could
hold the arbiter grant ahead of the only write capable of releasing the home
lock.  A started AMO and its bus fallback slot are also irrevocable across a
younger redirect, because cancellation after the marked read can strand the
lock.

LR and SC deliberately do not use `ccx_req_lock`.  Holding this lock from an
LR until some later SC would turn a reservation into an unbounded critical
section and can deadlock.  LR/SC therefore remain single-hart-local until the
home implements real reservations.

This scheme is acceptable only for current one-hart bring-up with one home,
one controlled ingress, and guaranteed release/reset behavior.  It does not
support coherent DMA or multi-hart operation, does not preserve `aq`/`rl`, and
does not replace the explicit home-executed LR/SC/AMO protocol specified
above.

## Private-cache probe protocol

Every private cache that can retain a physical line needs a decoupled probe
request and response path.  The minimum write-through protocol is:

```text
probe:      valid ready probe_id command line_addr
probe_resp: valid ready probe_id ack
```

`INV` is the only required initial command.  An L1 receiving it must:

- accept it immediately or place it in a bounded probe queue even while a CPU
  access, refill, or lower-level access is outstanding;
- invalidate a resident matching line;
- poison or cancel a matching transient refill so the line cannot be installed
  after the acknowledgement;
- acknowledge an absent line as a successful no-op; and
- assert acknowledgement only after the line can no longer produce a hit.

The probe path must not depend on completion of the transaction that is blocked
waiting for that probe.  In particular, an L2 eviction or store cannot wait for
an L1 acknowledgement while that L1 refuses the probe until its L2 refill
completes.  The current idle-only invalidation acceptance in `l1.v` must
therefore be replaced or fronted by a queue.

For an inclusive L2, a line may not be replaced until all recorded private
copies acknowledge invalidation.  A write may not become visible or complete
to its requester until conflicting private copies have been invalidated.

## Directory identity and policy

The recommended directory tracks instruction and data caches independently.
For 16 harts this is a 32-bit I/D sharer vector per L2 line.  That allows a D$
store to preserve or update its own D$ copy while targeting remote D$ copies
and whichever I$ copies the selected instruction-cache policy requires.

A smaller per-hart sharer vector is possible if one per-hart probe endpoint
fans every probe into both L1s and returns one combined acknowledgement.  It is
correct but causes avoidable invalidations and cannot distinguish the source
cache.

For the initial clean, write-through L1, directory information may be
conservative.  An L1 clean eviction need not immediately send a `PutS`; a stale
sharer bit merely causes a harmless probe to an absent line.  Exact ownership
becomes mandatory when private caches can contain dirty data.

## Instruction-cache behavior

If the L2 is described as inclusive, I-cache lines must participate in its
replacement probe protocol.  Whether every data store also snoops instruction
caches is a system policy choice, but tracking I$ and D$ separately keeps that
choice explicit.

Hardware I-cache coherence does not remove the architectural role of
`FENCE.I`.  The issuing hart must still:

1. wait until its older data writes are visible at the required coherence
   point;
2. invalidate its private I$ and resident frontend instruction state; and
3. restart instruction fetch after invalidation completes.

Cross-hart code modification additionally requires the software-defined remote
hart notification and remote `FENCE.I` sequence.

## Fences and ordering

Pipeline serialization alone is not memory-barrier completion.  The core must
turn architectural ordering operations into a request/drain contract visible
to the complex.

The first implementation may conservatively order more strongly than RVWMO:

- a release operation waits until older memory operations from that hart have
  completed at the required point;
- an acquire operation prevents younger memory operations from issuing until
  the acquire completes;
- `FENCE` waits for all older reads, writes, and atomics, sends a CCX fence
  token, and prevents younger memory operations from passing it; and
- `FENCE.I` performs the data-side drain before local instruction invalidation.

For the implemented L1D FIFO, a data-side drain means both the byte-masked
store FIFO and its core-bus tag FIFO are empty.  Merely enqueueing all older
stores is not fence completion.  The current execution path does not yet wire
architectural fences to this drain condition.

The existing two-bit CCX `order` field is sufficient for `aq` and `rl`.
Supporting selective `FENCE` predecessor and successor sets later will require
either additional fields or a deliberately documented full-fence
implementation.

Fences constrain the issuing hart.  They must not stop unrelated harts or
unrelated coherence granules merely because the first L2 controller happens to
be globally serialized.

## PTW and TLB integration

PTW memory requests must use the coherent physical path and carry `kind=PTW`
or an equivalent source identity.  PTW reads normally do not allocate a
private-cache line.

This matters even though the page walker is logically inside a hart: a PTE may
have been written through another hart's data cache.  A future write-back D$
also makes it possible for the newest PTE value to reside only in a private
cache, requiring normal coherent intervention.

The present PTW uses Svade-style fault-on-clear Accessed and Dirty bits.
Hardware A/D-bit updates, if added, must be atomic coherent read-modify-write
operations at the same home agent as RV64A atomics.

`SFENCE.VMA` invalidates the local TLB and prevents an overlapping stale walk
from refilling it.  Remote TLB shootdown is not an L2 probe operation; software
must request it through a per-hart interrupt mechanism.

## Recommended first coherent implementation

The first implementation should retain the current write-through,
no-write-allocate L1D and use Shared/Invalid state only.  The existing
Exclusive and Modified metadata must not become authoritative until ownership
is implemented.

The required sequence is:

1. A cacheable L1 miss requests a 512-bit line beat, or a multi-line burst when
   the endpoint has a valid contiguous prefetch/refill request.
2. Every returned line independently records the requesting endpoint as a
   sharer.
3. A write-through store invalidates every conflicting private copy and waits
   for all acknowledgements.
4. The L2 updates its byte-selected data and returns completion to the source.
5. An inclusive L2 replacement invalidates all recorded private copies before
   reusing the line.
6. LR, SC, and AMO requests bypass private allocation and execute at L2 after
   the required probes.
7. Device and non-cacheable requests bypass allocation and merging and never
   form multi-line bursts.

This requires only clean invalidation acknowledgements.  It does not require
cache-to-cache data transfer, dirty interventions, upgrades, or ownership
handoff.

The existing four-bit `op` field already uses fourteen of sixteen encodings for
architectural reads, writes, atomics, and fence.  Future cache-coherence
messages such as `GetS`, `GetM`, `Upgrade`, `PutS`, and `PutM` must not be
forced into the remaining encodings.  Either add a separate coherence-command
field or widen and restructure the request protocol before implementing a
write-back private cache.

## Later write-back L1 requirements

A write-back private L1 additionally requires:

- shared-read and exclusive-read/acquire requests;
- ownership upgrades;
- clean and dirty eviction notifications;
- downgrade and data-request probes;
- probe responses carrying a complete dirty line;
- one authoritative owner in the directory;
- transient states for fills, upgrades, interventions, and eviction races; and
- separate or otherwise deadlock-free request, response, probe, and probe-data
  flow control.

These mechanisms should not be introduced into the first write-through
coherence implementation unless measurement or another integration requirement
justifies them.

## Non-memory hart integration

Instantiating actual cores in the complex, rather than accepting external core
memory ports, also requires:

- one `HART_ID` parameter per core, passed both to CCX and the `mhartid` CSR;
- per-hart machine and supervisor software, timer, and external interrupts;
- boot-hart and secondary-hart reset/release policy;
- per-hart debug and halt selection; and
- removal of directory sharers and reservations on per-hart reset or powerdown.

DMA engines and other external memory writers are a separate system boundary.
They require either a coherent ingress into the home agent or a documented
non-coherent software cache-maintenance contract.  The AXI/WISHBONE master-only
southbound interface cannot observe writes that bypass the complex.

## Verification requirements

Coherence must be verified with integrated harts and enabled L1s, not only with
direct CCX or L2 testbench transactions.  At minimum, tests must cover:

- one hart reading a line after another hart writes it;
- one-line requests and multi-line bursts under request and response
  backpressure;
- partial-hit bursts in which some lines hit L2 and others require refill;
- burst splitting at physical-attribute changes and at the southbound AXI
  4 KiB boundary;
- simultaneous writes to the same word and to different words in one line;
- a store or L2 eviction probing an L1 with a matching refill in progress;
- false or stale directory sharer bits;
- LR/SC success without interference and failure after a conflicting write;
- every AMO against competing ordinary loads and stores;
- acquire/release message-passing and full-fence litmus tests;
- `FENCE.I` after self-modifying code;
- coherent PTW observation of PTE writes; and
- hart reset while it owns a reservation or appears in a sharer vector.
