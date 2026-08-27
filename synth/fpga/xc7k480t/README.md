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
