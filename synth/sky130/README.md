# Sky130 demonstration timing

`make sky130-liberty` downloads the merged Sky130 high-density standard-cell
library used by OpenROAD Flow Scripts.  The download is pinned to commit
`f255c15b3dd4362a704b6af9f617b4091bdd4e6a` and verified with SHA-256.  It is
stored under the ignored `sim/pdk/` directory rather than committed to this
repository.

The selected Liberty corner is `sky130_fd_sc_hd__tt_025C_1v80`: typical
process, 25 C, and 1.8 V.  `abc.constr` models each primary input as driven by
`sky130_fd_sc_hd__inv_2` and applies a 10 fF load to each primary output.

Run:

```sh
make yosys-timing-frontend-sky130
make yosys-timing-alu-rv64i-sky130
```

The reported ABC `stime` delay uses characterized cell arcs but no placement,
routing, extracted parasitics, clock tree, or on-chip variation.  Treat it as
pre-layout comparative timing, not signoff timing.
