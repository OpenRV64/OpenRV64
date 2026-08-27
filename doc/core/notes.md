# Core design notes

## Deferred: LSU translation-generation wrap

The 3P LSU translation cookie is currently `{generation[3:0], lsq_slot}`.
Squash and flush release an LSQ entry immediately; a response whose generation
does not match the current request for that raw slot is consumed as stale.

This deliberately has no live-generation bitmap or collision backpressure. A
two-bit generation was observed to wrap in Linux while a killed translation of
VA `0x60` remained in the MTL and the same raw LSQ slot issued four newer
translations. The generation was consequently widened to four bits. One
translation surviving sixteen newer translations on the same raw slot can
still alias its old response; add explicit lifetime tracking if that case is
observed or becomes reachable under the final translation-latency contract.

## Deferred: 4PF FPU branch-token reuse

The current selective-recovery scheme carries a four-bit unresolved-branch
mask with each FPU request. The implementation does not use that modulo-four
mask as completion identity: `(retirement slot, instruction ID)` remains
authoritative for squash and late-result matching. Token reuse therefore does
not currently corrupt state.

This becomes a correctness concern if a later timing optimization drops the
exact-ID check and relies on the mask for early kill. In that design, either:

- delay reuse until all FPU operations carrying that token have drained; or
- add a token generation/epoch to the FPU completion tag and recovery check.

## 4PF memory issue rate

The initial 4PF window issues at most one memory operation per cycle. The 3P
window's dual-memory coupling lets execution readiness affect valid generation.
The F/D transfer-capacity dependency has been removed: loads use slot-owned
result state, and stores are prebuffered through a dedicated FPR read port.
That change adds no sidecar ready dependency to integer LSU arbitration.

A direct attempt to restore paired integer memory issue still formed a
wrapper-level combinational loop through issue valid and execution readiness.
Restoring two memory issues therefore requires an explicit registered
skid/reservation boundary. Do not reconnect sidecar readiness or private
register data directly to LSU ready/valid.

## Deferred: full-core FMV.X.D progress

The initial compute-only DAXPY setup issued `FMV.D.X` writes to `f0` through
`f17`, followed by `fmv.x.d t1,f17` as a drain check.  The 4PF full-core test
made no further progress at the `FMV.X.D` for 100,000 cycles.  Removing that
transfer and relying on ordered retirement of the following phase marker made
the compute-only DAXPY test pass.  Post-measurement FPR validation through
`FSD` plus integer `LD` also passed.

This is evidence of a 4PF FPR-to-GPR transfer progress bug, but its precise
cause is not isolated.  Add a directed full-core test covering a single
`FMV.D.X`/`FMV.X.D` pair, a source dependent on a resident result, GPR result
retirement, and a window-saturation sequence before changing the transfer
path.
