# XC7K480T core synthesis

This directory contains a board-independent, out-of-context synthesis flow for
the OpenRV64 three-pipe core on `xc7k480tffg1156-2`.

The default measured profile is the full single-hart 3P Linux profile rather
than the reduced 1P FPGA profile:

- RV64IMA, Zbb, and Zicclsm enabled
- 32-entry retirement structure
- issue and speculation windows enabled
- tournament predictor with RAS
- 16 KiB L1I and 16 KiB L1D
- 256-entry, four-way L2 TLB and 64-entry PTE cache
- trace disabled

The core boundary excludes the shared L2, memory controller, and peripherals.
`default.xdc` constrains only the 50 MHz core clock. It deliberately contains
no package pins or I/O standards because those are board-specific.

Run the part-independent Xilinx 7-series primitive mapping with:

```sh
run/run fpga-xc7k480t-3p-utilization
```

Run the 32-entry retirement/32-entry Tomasulo scheduler profile with the L1
cache arrays disabled using:

```sh
run/run fpga-xc7k480t-3p-tomasulo32-cacheless
```

That configuration uses the installed `xc7a100tfgg484-2` support as a native
Vivado 7-series synthesis proxy because this installation does not contain the
`xc7k480tffg1156-2` device files.  Its absolute primitive counts and preserved
hierarchy are useful for sizing against the K480T capacity, but its
device-relative percentages and synthesis timing are for the A100T and are not
K480T placement or routing results.  The corresponding area-oriented cross
check is:

```sh
run/run fpga-xc7k480t-3p-tomasulo32-cacheless-area
```

`ENABLE_L1I=0` and `ENABLE_L1D=0` disable the cache arrays.  They do not yet
remove the L1 ICX wrapper/control paths; in particular, the L1D transaction and
tag-overlay machinery remains.  The 256-entry L2 TLB also remains because it
is translation state, not an L2 data cache.

The whole-core mapping preserves the existing RTL hierarchy. It does not pass
the complete 3P core to ABC as one flattened Boolean network.

Build the initial source-adjacent module statistics histories with:

```sh
run/run fpga-xc7k480t-module-stats
```

`module_stats.json` selects the current boundaries. Each selected source gets
a `<source-stem>_stats.md` file containing newest-first build records with the
effective parameters, commit and dirty state, input digest, mapped resources,
structural path depth, and diagnostics. These standalone boundaries currently
overlap; do not sum their counts as though they were exclusive partitions.

The local Vivado installation must include Kintex-7 device support before the
device-relative report can be generated with:

```sh
make fpga-xc7k480t-3p-utilization
```

The latter produces `utilization.rpt`, a synthesis timing estimate, and an
out-of-context DCP. It is not placement, routing, or bitstream evidence.
