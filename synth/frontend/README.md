# Frontend synthesis reports

Run the pinned Sky130 pre-layout reports with:

```sh
make yosys-timing-frontend-sky130
```

The reports under `sim/yosys/frontend/` are separate timing cuts:

- `replay-lookup.rpt` measures only the two-set, four-way resident-line lookup.
- `full-replay.rpt` measures the current same-edge path from registered direct-
  control metadata, through the direction policy and resident lookup, to the
  replay instruction.
- `predecode-target.rpt` measures instruction classification, immediate
  extraction, and prefix target addition after a line fill. Its result is
  registered with the resident line, so this path is not in same-edge replay.

These are Liberty cell-delay reports, not routed timing. They omit placement,
interconnect extraction, clock uncertainty, and setup/hold checks.
