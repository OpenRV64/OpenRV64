# Core design notes

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
Adding FPU transfer-capacity readiness to that path formed a real combinational
loop. Restoring two memory issues requires an explicit registered
skid/reservation boundary; do not reconnect sidecar ready directly to LSU
ready/valid.
