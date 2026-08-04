# Nangate45 exploratory synthesis

The Nangate Open Cell Library remains an external build dependency. Run:

```sh
make nangate45-liberty
```

This downloads `NangateOpenCellLibrary_typical.lib` into the ignored
`sim/pdk/nangate45/` cache. The source is pinned to OpenROAD Flow Scripts
commit `f255c15b3dd4362a704b6af9f617b4091bdd4e6a` and verified with SHA-256.
The library itself is not committed to this repository.

Available synthesis entry points are:

```sh
make yosys-timing-frontend-nangate45
make yosys-timing-alu-rv64i-nangate45
make -j2 yosys-resources-core-4pf-nangate45
```

The last target maps matched cacheless 4PF configurations with and without
RV64F/RV64D. It may also be run directly, in which case the report script pulls
and verifies the external Liberty dependency itself:

```sh
synth/nangate45/report-core-4pf.sh fd
synth/nangate45/report-core-4pf.sh nofd
```

The full-core area is summed across retained functional partitions so ABC can
map them in parallel. The reported delay is the worst delay within any one
partition, not flattened whole-core static timing across partition boundaries.
The full-core flow uses
`strash; dretime; strash; &get -n; &nf; &put` because the default FRAIG/DCH
recipe is impractical on the 4PF dispatch and FPU partitions, while ABC's fast
constrained recipe aborts during buffer sizing on a fanout-free node. The map
therefore omits buffer/upsize/downsize optimization; area and delay remain
exploratory synthesis estimates.

The selected liberty is the typical-process, 25 C, 1.1 V corner. The ABC
constraint uses the platform's `BUF_X1` input driver and 3.898 fF output load.
Reports are pre-layout cell mapping and timing estimates, not signoff PPA.
