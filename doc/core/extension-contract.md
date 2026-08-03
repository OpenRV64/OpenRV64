# Core extension contract

An architectural extension is a sidecar, not a special execution class in the
integer core.  Shared frontend, window, CSR, and retirement RTL may carry
generic extension signals, but must not interpret an extension's opcodes,
private registers, result format, or architectural state.

## Identity and lifetime

The parent core owns program order.  Every allocated instruction receives the
pair `(retirement slot, instruction ID)`.  The slot is a physical index and may
be reused; the wrapping age ID prevents a late response from aliasing a new
occupant.  The live window must remain smaller than half of the ID namespace so
modular age comparisons are unambiguous.  Every extension completion, memory
response, and retirement candidate must match both values.

Full redirects flush all extension state.  Selective branch recovery removes
only instructions younger than the named branch ID.  The parent supplies an
opaque four-bit unresolved-branch mask with each extension allocation/request;
the parent owns token allocation and reuse policy.

## Decode and allocation

`openrv64_decode_early` identifies an otherwise-unowned major opcode only as a
generic extension candidate.  An enabled extension decoder may claim it and
return ordinary scheduling metadata plus an opaque payload.  If no enabled
extension claims the candidate, normal decode reports illegal instruction.

The parent window carries:

- the ordinary integer issue payload;
- the opaque extension payload;
- the branch mask; and
- the retirement identity pair.

Only the extension sidecar interprets the opaque payload or private-register
metadata.  Allocation valid into a sidecar is qualified by that sidecar's
decode claim; ordinary instructions do not allocate sidecar state.  A
non-extension retirement candidate must appear ready to the sidecar and must
produce no extension side effects.  Consequently, extension result storage is
sparse and is empty for the common integer-only cycle.

The shared decoder exposes one composed extension response.  If several
extensions are present, an extension composition layer must arbitrate their
claims and reject multiple claimants; the integer decoder does not encode a
priority among extensions.

## Scheduling and memory

The parent combines global eligibility, GPR readiness, memory ordering, and the
extension's private-operand readiness.  The extension selects among globally
eligible extension entries and obeys ordinary valid/ready backpressure.

The LSU remains unaware of private registers.  A memory transfer is identified
by `(slot, ID)` and uses the ordinary LSU/LSQ for ordering, translation,
protection, faults, and completion.  An extension load captures the returned
value into extension-owned, slot-indexed result state on the same exact-tagged
LSU event.  It does not emit a duplicate extension-completion token.  An
extension store prebuffers its private-register operand before the parent
asserts the ordinary LSU request; once presented, it is ordinary store data.

On accepted load issue, the LSU exposes a generic assignment notification
containing `(slot, ID, rd, size)`.  `rd` is only an architectural destination
number at this boundary; the LSU does not decide which register file owns it.
An extension that writes private state must reserve its destination during
decode, before younger dependency capture, then use this notification to
confirm that the exact load crossed into the shared LSQ.  A matching load
result or load fault is invalid unless that assignment was observed.  The
notification validates ownership and transfer width; it is not a second queue
and does not increase memory concurrency.

Private operand availability must not feed a combinational ready/valid loop
through the integer LSU.  If the parent supports paired memory issue, the
extension boundary needs a registered reservation or skid stage.  Integer-only
memory issue must not arbitrate with, or consult, an inactive sidecar.

Memory exceptions remain ordinary LSU completion records.  The sidecar
receives the faulting identity only to release private wait state; it does not
replace the LSU cause, address, or precise-retirement decision.

## Completion and retirement

Non-memory execution results remain in extension-owned, slot-indexed storage.
After such a result is resident, the sidecar emits a sparse completion token
containing only `(slot, ID)`.  Memory operations use the ordinary LSU
completion record instead.  In both cases the integer retirement queue records
only its normal completion bit; it does not acquire extension result or
private-register fields.

For the ordered retirement candidates, an extension returns:

- per-lane readiness;
- an optional cross-domain GPR result;
- an optional precise exception, cause, and `tval`; and
- extension-private retirement effects on its own interface.

The integer retirement prefix stops at an unready extension lane.  It consumes
generic GPR results and precise exceptions exactly like integer results.  The
actual parent acceptance vector is returned to the sidecar; only that event may
write private registers, accrue extension state, release private dependencies,
or discard the stored result.

## CSR state

The integer CSR block performs common CSR privilege/read-only validation and
offers a generic extension CSR response port.  An extension owns its CSR data,
write readiness, `misa` contribution, and disjoint `mstatus`/`sstatus` overlay
bits.  Validated extension-CSR and status-write pulses are returned to the
sidecar.  Extension state changes and writes to overlapping status/extension
CSRs must be serialized in retirement order.

## Current width and resource policy

The initial contract has one sparse extension-completion port, four unresolved
branch tokens, and up to three ordered retirement candidates.  Multiple
sidecars must arbitrate the single completion port outside integer retirement.
These are policy choices, not FPU semantics.  A sidecar may further restrict
retirement.  The F/D sidecar currently permits one private FPR write per cycle
and bypasses resident results only by exact `(slot, ID)` producer tags.
