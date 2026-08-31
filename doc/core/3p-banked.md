# Conservative banked 3P backend

The banked 3P profile is a functional variant of the normal 3P backend.  It
uses the shared decode, execution, memory, exception, and retirement-record
paths, but replaces the combinational multiported integer GPR storage with a
request/response banked file.  The initial profile deliberately limits issue
and retirement to two instructions and disables policies that assume
combinational operands or retained completion forwarding.

This is functional parity work, not performance parity.  In particular, a
dependent instruction waits for its producer to write the GPR file and for a
subsequent registered read response.

## Profile

The conservative configuration uses:

- four logical read ports and two logical write ports;
- two single-read/single-write banks covering physical registers p0-p31;
- at most two issue lanes and two retirement lanes;
- no completion-forward mask, branch-completion forwarding, full forwarding,
  relaxed WAW handling, issue window, or speculation window;
- the existing 32-entry retirement queue and p1-p31 architectural storage.

Physical p0 is structural: reads return zero without issuing a bank request,
and writes acknowledge without modifying storage.  The storage arrays
therefore do not require reset initialization for x0 correctness.

## Request contract

Each requester holds request, address, and write data stable until its
combinational `ack`.  Ack is the accepted address phase.  On the following
cycle the requester may present a different address while the acknowledged
read's registered data and valid return as the data phase.  The requester
registers ack and uses that bit to associate the next-cycle response; a bare
valid is not ownership metadata.  There is no per-port response bubble, so a
logical port can accept one transaction per cycle when its bank wins.

Arbitration may acknowledge only one read and one write per bank per cycle.
A conflict simply withholds ack, causing the loser to retry its held address.
`quiescent_o` means that no accepted response remains in the file; a complete
caller-side busy predicate also includes requests still being presented:

```text
busy = any_request || !quiescent_o
```

An independently granted read and write to the same physical word returns the
new write data through the read-response latch.  This defines the storage
collision rather than depending on inferred RAM read-during-write behavior.

The backend blocks a normal operand read while the architectural destination
is busy.  Consequently, a dependent load consumer follows this sequence:

1. the load completes into its retirement record;
2. retirement holds the GPR write until the file accepts it;
3. the storage update and write ack occur at the write-grant edge;
4. the ack permits architectural retirement and the scoreboard clears; and
5. the consumer obtains an acknowledged address phase followed by a registered
   GPR read data phase and may issue.

The same-address register-file bypass is therefore a correctness definition
for an independently granted collision, not a load-completion forwarding
path.

## Redirect handling

A redirect enters a drain state.  New GPR reads and allocation remain blocked
until all presented requests and registered responses have cleared.  An
unacknowledged request keeps its latched address (and write data, for
retirement) stable through the redirect until ack.  An acknowledged read is
already irrevocable and its following data phase is poisoned and discarded,
rather than captured as an operand for the redirected instruction stream.

Simulation contains a 100-cycle watchdog for every held logical read and
write request waiting for ack.  The watchdog is excluded from synthesis and
reports the port and physical address on timeout.  A separate 100-cycle
watchdog covers redirect drain through the final poisoned data phase.

## Retirement boundary

When banked retirement captures a candidate group, it freezes that group's
lane mask along with its write masks, addresses, and data.  A younger lane that
becomes ready while the captured writes drain cannot retire as part of that
group.  It is handled by a subsequent write transaction.  This is required;
allowing the live retirement-valid mask to grow would accept a result whose
GPR write was never captured.

The wrapper also completes every GPR write in a retirement group before it
exposes that group's CSR request.  This ordering matters for PMP and SATP:
their CSR completion can assert a core control flush on the same edge.  If the
CSR request were allowed to complete first, that flush could discard the
wrapper's still-pending GPR result from a `csrrw` instruction.

If an unrelated redirect arrives while a retirement write is waiting on a
bank, the wrapper retains the captured mask, addresses, and data until every
write ack arrives.  It then discards the flushed queue association.

CSR requests use the same transaction rule.  The wrapper latches the CSR
address, operation, and data, holds the request independently of a redirect,
and registers the response before allowing the instruction to retire.  An
unrelated redirect marks the response for discard but does not cancel the
transaction.  This is also required for self-flushing PMP and SATP writes:
their own flush cannot combinationally remove the request that caused it.

The banked ordered-memory selector uses the current registered retirement
queue head.  It deliberately does not use the normal post-retirement
fall-through head because the banked retirement and scoreboard release paths
include the storage acknowledgement cycle.

## Managed validation

The following managed runs passed on 2026-08-31:

- `3p-banked-directed-20260831T184810Z`: register-file arbitration and
  collision bypass, p0 semantics, held requests, redirect draining, the
  late-ready retirement case, GPR-before-CSR side-effect ordering, a CSR
  transaction held across redirect, a pending GPR write held across redirect,
  two-wide backend flow, and an end-to-end memory program.  The program
  includes `ld x29,...` immediately followed by `addi x30,x29,1` and verifies
  the stored result.
- `coremark-bare-smoke-3p-banked-ddr3-20260831T105928Z`: timed-DDR3 bare-metal
  CoreMark-derived workload, 1,494,215 cycles and 358,184 retired
  instructions, with the expected `a0=0x434d4f4b` marker.
- `coremark-sv39-3p-banked-ddr3-20260831T171656Z`: supervisor Sv39 workload,
  221,860 cycles and 52,589 retired instructions.  It confirmed Sv39 SATP,
  supervisor execution, aliased instruction and data access, and six PTW
  reads.
- `lsu-xlate-generation-3p-20260831T171818Z`: the existing non-banked 3P
  execution, backend, top, ICX, and L1I regression, run after moving banked
  support into the shared backend.  All five component and full-core checks
  passed.
- `compliance-act4-platform-3p-banked-ddr3-20260831T183548Z`: all 93 preserved
  RV64IMA ACT4 ELFs passed on the one-hart 3P platform with the integrated L2
  and timed-DDR3 endpoint.  The set comprises 51 RV64I, 13 RV64M, 18 Zaamo,
  four Zalrsc, six Zicsr, and one Zifencei test.  The harness requires an
  accepted timed-DDR3 read command before reporting each pass.
- `compliance-act4-platform-3p-ddr3-20260831T184216Z`: the matching current-3P
  L2/timed-DDR3 control also passed the same 93 ELFs.

These results establish focused simulation and timed-memory/Sv39 behavior.
The ACT4 result uses preserved generated ELFs under the ignored build tree; it
does not regenerate or re-establish the provenance of the external suite.
These results do not establish performance parity, Linux boot, inferred FPGA
memory mapping, routed timing, physical FPGA operation, or certification.

For scale, the current aggressive RD32 baseline run
`coremark-bare-smoke-rd32-ddr3-20260827T015108Z` completed the corresponding
bare workload in 456,429 cycles at 0.7847 IPC.  The conservative banked run
needed 1,494,215 cycles at 0.2397 IPC, about 3.27 times as many cycles.  This
comparison includes the intentionally disabled issue/speculation windows,
forwarding, and WAW relaxation; it is not an isolated register-file latency
measurement.
