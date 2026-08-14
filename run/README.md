# Run infrastructure

`run/run` is the common entry point for builds and simulations that need a
durable record. Configuration files under `run/cfg/` describe a workload and
select a target backend. Backends build and execute targets; the common layer
owns discovery, status, logs, attach/wait/stop, and the run-directory contract.

Every launch creates:

```text
run/log/<configuration-name>-<UTC timestamp>/
```

The directory records the configuration snapshot, exact command and Make
arguments, effective values, Git state and dirty-tree patch, source and
artifact hashes, snapshotted artifacts, build/run logs, heartbeat, and final
validation status. It is the place to inspect results; workload-specific
scripts must not invent separate log locations.

## Bare-metal first

The first target-neutral backend runs ordinary Make build and simulation
targets. BLAKE2s provides baseline and Zbb configurations:

```sh
run/run blake2s-bare-metal-generic
run/run blake2s-bare-metal-zbb
run/run blake2s-bare-metal-zbb --foreground
run/run blake2s-bare-metal-zbb --manifest-only
```

The BLAKE2s configs run both the functional test and the measured workload.
Success therefore requires the bare AXI-SRAM `PASS` marker and a
`PERF_BLAKE2S` result, not merely a zero process exit.

Bare-metal start overrides are `--jobs N`, `--rebuild`, `--foreground`,
`--manifest-only`, `--timeout-seconds N`, and Make-style `NAME=value`
assignments.

Managed jobs have a 259200-second (72-hour) wall-clock timeout covering both
build and execution. A configuration may override it with
`RUN_TIMEOUT_SECONDS`; `--timeout-seconds N` overrides one invocation, and
zero explicitly disables the timeout. A timed-out record ends with
`validation=timeout` rather than being reported as an ordinary simulator
failure.

## Control surface

The same commands operate on all managed targets, including older Linux run
directories whose metadata predates the common target fields:

```sh
run/run status latest
run/run list
run/run log latest 80
run/run tail latest
run/run attach latest
run/run path latest
run/run checkpoint latest
run/run command latest
run/run wait latest
run/run stop latest
```

`latest`, an exact run ID, a configuration-name prefix, or a run-directory path
selects a run. `run/run.sh` is only a compatibility alias for `run/run`.

## Extension ladder

Target growth is intentionally staged so failures stay attributable:

1. Bare-metal payload on the AXI SRAM model.
2. The same payload on the timed DDR3 model.
3. Sv39 execution, still without firmware or Linux.
4. Platform/OpenSBI boot and multi-hart machinery.
5. Full Linux build and boot validation.

Only stage 1 uses the new Make backend today. `linux-smp` remains the existing
target-specific backend in `tools/run-linux-smp.sh`; `run/run` now supplies its
common entry point and controls. DDR3, Sv39, and OpenSBI are not claimed as
migrated merely because their Make targets already exist.

## Linux target

Existing Linux configurations remain valid:

```sh
run/run linux-smp-4h-ddr3
run/run linux-smp-4h-ddr3 --rebuild
run/run linux-smp-4h-ddr3 --checkpoint 18000000 --checkpoint-exit
run/run linux-smp-4h-ddr3 --resume RUN_OR_CHECKPOINT
```

Resume copies the source run's checkpoint, exact snapshotted simulator, and
inputs into a new timestamped record. It does not rebuild current RTL against
old serialized state. Unless a new checkpoint is supplied, resume disables the
configuration's normal checkpoint.

Configurations may set `RUN_KERNEL_ELF` to the `vmlinux` matching `RUN_IMAGE`.
The Linux backend verifies the Image, snapshots the ELF, and generates Linux
and OpenSBI symbol maps for progress reporting.
