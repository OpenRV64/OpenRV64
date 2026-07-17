# ALU synthesis reports

Run generic mapped-gate depth reports with:

```sh
make yosys-timing-alu
```

The generic reports compare structure and logic depth. They are not timing in
nanoseconds because no cell delays or physical routing are available.

For technology timing, provide a Liberty cell library. An ABC constraint file
is strongly recommended so primary-input drive and output load are explicit:

```sh
make yosys-timing-alu \
    LIBERTY=/path/to/cells.lib \
    ABC_CONSTR=/path/to/abc.constr \
    ABC_DELAY_PS=1000
```

`ABC_DELAY_PS` is the mapping target in picoseconds. Reports are written under
`sim/yosys/alu/`. Use `make yosys-timing-alu-rv64i` or
`make yosys-timing-alu-rv64m` to report one unit only.

For the pinned Sky130 demonstration library and constraints, run:

```sh
make yosys-timing-alu-rv64i-sky130
```

Technology delay is ABC `stime` output from Liberty lookup tables.  It is
pre-layout timing and does not include routed interconnect or clock effects.

The RV64-I set contains an integrated report and constant-operation wrappers.
The wrappers measure the isolated datapath after operation-selection logic has
been removed. The integrated report includes the actual ALU result mux.

RV64 ADD, SUB, and AUIPC use the explicit six-level parallel-prefix network in
`rtl/core/arith/prefix-addsub.v`. ADD/SUB and AUIPC have independent networks
so normal arithmetic does not inherit an input mux. This is intentionally an
area-for-timing implementation; it is not an inferred `+`/`-` comparison.
