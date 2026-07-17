# Operand forwarding

The core enables arithmetic-result forwarding by default. The implementation
has two independent controls:

- `ENABLE_FORWARDING=1` allows a consumer to issue behind an older GPR writer
  and forwards the EX/MEM value into ALU, branch, LSU-address, and store-data
  operands.
- `ENABLE_LOAD_FORWARDING=0` keeps a one-cycle load-use bubble. Setting it to
  `1` forwards a completing load directly from the memory response into EX.

The second control is deliberately off by default. Direct load-use forwarding
creates a combinational path from `mem_rdata_i`, through load extraction and
the operand mux, into the following execution unit. It improves cycle count,
but its Fmax cost cannot be evaluated without a technology library and routed
design.

Dispatch is forwarding-aware. Its per-register writer state is a count rather
than a busy bit, because read-modify-write chains can have multiple writes to
the same register in flight. RAW stalls are suppressed only when the producer
is moving into, or is available from, EX/MEM. WAW and WAR do not require
serialization in this single-issue, in-order pipeline; results still retire in
program order.

## Measured software trace

All rows below ran the same 112-byte `sw/test.bin`, retired 1,022 instructions,
returned `a0=100`, and raised no exceptions.

| Forwarding | Load bypass | BP policy | Cycles | IPC |
| --- | --- | --- | ---: | ---: |
| off | off | stall | 4,691 | 0.2179 |
| on | off | stall | 2,971 | 0.3440 |
| on | on | stall | 2,871 | 0.3560 |
| on | on | always taken | 2,773 | 0.3686 |
| on | on | repeat last | 2,774 | 0.3684 |

The default forwarding mode removes 1,720 cycles, a 36.7% cycle reduction and
a 57.9% IPC increase. Full load bypass removes another 100 cycles. The taken
predictors save roughly another 100 cycles on this taken-loop workload, but a
single loop is not enough evidence to change the default branch policy.

The default run is:

```sh
make sim-sw-trace SW_BIN=sw/test.bin
```

The main experiment controls are `SW_FORWARDING`, `SW_LOAD_FORWARDING`, and
`SW_BP_TYPE`. For example, full load bypass with the repeat-last predictor is:

```sh
make sim-sw-trace \
  SW_FORWARDING=1 SW_LOAD_FORWARDING=1 SW_BP_TYPE=3
```
