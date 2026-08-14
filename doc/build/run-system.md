# Configuration-driven run system

Long-running simulations are selected by named files under `run/cfg/`. Do not
reconstruct a target from an ad-hoc Make command, simulator command, tmux
session, and monitor. The configuration file is the durable description of
the target; the generated run directory is the durable record of one
invocation.

The canonical invocation is an executable configuration file:

```bash
run/cfg/linux-smp-4h-ddr3.cfg
```

That creates a directory named after the configuration and its UTC start time:

```text
run/log/linux-smp-4h-ddr3-20260802T001440Z/
```

The common runner accepts the same configuration by basename or path:

```bash
run/run linux-smp-4h-ddr3
run/run linux-smp-4h-ddr3.cfg
run/run run/cfg/linux-smp-4h-ddr3.cfg
```

## Repository layout

```text
run/
├── cfg/
│   ├── linux-smp-2h-ddr3.cfg
│   ├── linux-smp-4h-ddr3.cfg
│   └── linux-smp-4h-user-tests-ddr3.cfg
├── log/
│   └── <configuration-name>-<UTC timestamp>/
├── README.md
└── run
```

`run/run` is the common frontend. `tools/run-linux-smp.sh` is the current
target-specific backend; normal use should go through a configuration file.
The backend resolves the actual Make-derived simulator and artifact paths,
builds them under a shared build lock, snapshots them, and launches one
detached tmux session that owns the simulation and progress monitor.

## Current configurations

The checked-in coherent Linux configurations are:

| Configuration | Active harts | Verilator threads | Memory model | Swizzle |
|---|---:|---:|---|---:|
| `linux-smp-2h-ddr3.cfg` | 2 | 1 | timed DDR3 | 0 |
| `linux-smp-4h-ddr3.cfg` | 4 | 1 | timed DDR3 | 0 |
| `linux-smp-4h-user-tests-ddr3.cfg` | 4 | 1 | timed DDR3 | 0 |

The first two configurations select `sw/Image.smp`.  The user-test target
selects `sw/Image.smp-user-tests`, whose initramfs runs the quick Linux
userspace SMP/coherence/VM suite before opening the shell.  All three select:

- Zicclsm advertisement enabled;
- 250 million maximum cycles;
- a non-terminating checkpoint at 25 million cycles;
- L1D prefetch enabled;
- DDR read/write/command queue depths of 8/8/16;
- maximum DDR burst train of 8;
- generic-bus read/write depths of 8/8;
- a 15-minute progress-notification interval.

One Verilator runtime thread is intentional. Thread count is a target
configuration, not a host-side optimization to change casually: prior
measurements showed substantial synchronization overhead with multiple
runtime threads.

## Starting runs

Start the four-hart reference configuration:

```bash
run/cfg/linux-smp-4h-ddr3.cfg
```

Start the two-hart reference configuration:

```bash
run/cfg/linux-smp-2h-ddr3.cfg
```

Force a complete rebuild before launch:

```bash
run/cfg/linux-smp-4h-ddr3.cfg --rebuild
```

Without `--rebuild`, Make performs its normal dependency-aware incremental
build. The run still snapshots and hashes the resolved executable and inputs.
Use `--rebuild` when the requested experiment explicitly requires a clean
source-matched rebuild, not as a substitute for understanding dependencies.

Override the cycle limit and checkpoint for one run:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    --max-cycles 80000000 \
    --checkpoint 18000000
```

Disable checkpoint creation for a short run:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    --max-cycles 5000000 \
    --checkpoint 0
```

Save a checkpoint and terminate cleanly at that point:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    --checkpoint 33000000 \
    --checkpoint-exit
```

`--checkpoint-cycles` remains an alias for `--checkpoint`.

For an early failure whose exact arrival cycle is not yet known, save periodic
checkpoints and stop after saving one that observes a specified hart-0 PC:

```bash
run/run run/cfg/linux-coherent-1h-ddr3.cfg \
    --max-cycles 5000000 \
    --checkpoint 0 \
    --checkpoint-interval 1000000 \
    --checkpoint-stop-pc 0x8010f370
```

Periodic snapshots are named `checkpoint-<cycle>.vls`.  The stop-PC comparison
is made when each periodic checkpoint is saved, not on every simulated cycle.

Resume a managed run's newest checkpoint with the exact simulator and input
snapshots that created it:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    --resume linux-smp-4h-ddr3-checkpoint33m-20260802T012045Z
```

Resume a specific checkpoint and stop after a bounded replay interval:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    --resume run/log/linux-smp-4h-ddr3-checkpoint33m-20260802T012045Z/checkpoint-33000000.vls \
    --max-cycles 35000000 \
    --stop-cycles 33500000
```

`--resume` accepts a managed run ID, managed run directory, or checkpoint
path. A run ID or directory selects its newest checkpoint. Resume creates a
new timestamped run record and reflink-copies, where supported, the source
checkpoint, exact snapshotted simulator, firmware, DTB, kernel, and memh.
Current RTL is not rebuilt against old serialized state. Hart count and
Verilator thread count must match the checkpoint source.

Unless the resume command explicitly supplies a new `--checkpoint`, the
configuration's normal checkpoint is disabled. `--max-cycles` becomes the
restored testbench's absolute maximum-cycle override; `--stop-cycles` is also
an absolute cycle, not a number of cycles after restore. A new checkpoint
cycle on a resumed run is absolute as well and should normally be greater than
the restored cycle.

Override a Make parameter for an explicitly labeled experiment:

```bash
run/cfg/linux-smp-4h-ddr3.cfg \
    OPENSBI_4H_DDR3_BANK_ROW_SWIZZLE=1
```

The generated directory still uses the configuration filename. Therefore,
frequently reused or reportable variants should get their own configuration
file instead of relying on an override whose meaning is absent from the run
name. For example, a durable swizzle experiment should be copied to a file
such as `run/cfg/linux-smp-4h-ddr3-swizzle1.cfg` and edited there.

Command-line start options and Make-style `NAME=value` arguments are applied
after configuration defaults and therefore take precedence. Additional
simulator plusargs may follow `--`; every such argument must begin with `+`.

Every managed job has a whole-job wall-clock timeout, including its build and
simulation phases. The default is 259200 seconds (72 hours). Set
`RUN_TIMEOUT_SECONDS` in a configuration, use `--timeout-seconds N` for one
launch, or use zero to disable the limit explicitly. Timeout completion is
recorded as `validation=timeout` with `timed_out=1`.

## Configuration format

Configuration files are repository-controlled Bash fragments. They are both
sourceable by `run/run` and executable directly. Do not execute an unreviewed
external configuration file.

A coherent Linux configuration has this shape:

```bash
#!/usr/bin/env bash
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    exec "$(cd "$(dirname "$0")/.." && pwd)/run" "$0" "$@"
fi

RUN_CONFIG_VERSION=1
RUN_TARGET=linux-smp
RUN_DESCRIPTION='Four-hart coherent Linux boot on timed DDR3.'

RUN_HARTS=4
RUN_THREADS=1
RUN_IMAGE=sw/Image.smp
RUN_ZICCLSM=1
RUN_MAX_CYCLES=250000000
RUN_CHECKPOINT_CYCLES=25000000
RUN_MONITOR_SECONDS=900
RUN_TIMEOUT_SECONDS=259200
RUN_REBUILD=0

RUN_MAKE_ARGUMENTS=(
    CORE_4H_3P_L1D_PREFETCH_ENABLE=1
    OPENSBI_4H_DDR3_ENABLE=1
    OPENSBI_4H_DDR3_READ_QUEUE_DEPTH=8
    OPENSBI_4H_DDR3_WRITE_QUEUE_DEPTH=8
    OPENSBI_4H_DDR3_COMMAND_QUEUE_DEPTH=16
    OPENSBI_4H_DDR3_MAX_BURST_TRAIN_BURSTS=8
    OPENSBI_4H_DDR3_BANK_ROW_SWIZZLE=0
    OPENSBI_4H_GENBUS_READ_DEPTH=8
    OPENSBI_4H_GENBUS_WRITE_DEPTH=8
)
```

The output directory name comes from the configuration filename, not
`RUN_DESCRIPTION`. Filenames must contain only letters, digits, dots,
underscores, and hyphens. If two launches obtain the same name and timestamp,
the backend appends its process ID instead of overwriting the first record.

`RUN_TARGET=linux-smp` currently supports two or four active harts. The older
single-hart/3P runner has not yet been migrated into this configuration
system.

## Generated run record

A successful build followed by a running simulation produces a record similar
to:

```text
run/log/linux-smp-4h-ddr3-20260802T001440Z/
├── artifacts.sha256
├── build.log
├── checkpoint-25000000.vls
├── comment.txt
├── effective-config.txt
├── git-head.txt
├── git-status.txt
├── inputs/
│   ├── Image.smp
│   ├── fw_jump.elf
│   ├── fw_jump.memh
│   ├── hsm-wfi-pc.txt
│   ├── linux-image.memh
│   ├── opensbi_4h_checkpoint_tb
│   ├── openrv64-3p.dtb
│   ├── openrv64-3p-dtb.memh
│   └── trampoline.memh
├── make-arguments.txt
├── manager.env
├── run.cfg
├── run.log
├── resume.vls
├── simulator-arguments.txt
├── source-inputs.sha256
├── source-inputs.txt
├── status
├── test-name.txt
└── worktree.patch
```

Files appear as their phases complete. A configuration or build failure will
not have simulation artifacts or a `run.log`; a simulation that ends before
the checkpoint cycle will not have a checkpoint. `resume.vls` exists only for
a resumed run and is that run's private checkpoint snapshot.

Important files are:

- `run.cfg`: launch-time snapshot of the selected configuration for this run;
- `manager.env`: resolved run ID, path, hart/thread counts, session name, and
  command metadata;
- `effective-config.txt`: Make's resolved configuration, including derived
  simulator and artifact paths;
- `git-head.txt`, `git-status.txt`, and `worktree.patch`: exact repository
  provenance for tracked changes;
- `source-inputs.txt` and `source-inputs.sha256`: build dependency manifest and
  content identities;
- `inputs/`: private executable, kernel, firmware, DTB, memh, and HSM-PC
  snapshots consumed by the simulation;
- `artifacts.sha256`: identities of those private snapshots;
- `build.log`: configuration/build command and compiler output;
- `run.log`: exact simulator command, UART/progress output, failure evidence,
  simulator exit status, and boot validation;
- `status`: final phase, exit status, simulator status, and validation result;
- `checkpoint-<cycle>.vls`: replay state when checkpointing is enabled and the
  configured cycle is reached.
- `resume.vls`: private copy or reflink of the checkpoint consumed by a resumed
  run.

The shared build lock covers configuration-dependent compilation and input
snapshotting. It is released before simulation, so already-snapshotted runs
may execute in parallel without racing a later build.

## Status and lifecycle commands

Show the newest generated run:

```bash
run/run status latest
```

Show a specific run by ID or directory:

```bash
run/run status linux-smp-4h-ddr3-20260802T001440Z
run/run status run/log/linux-smp-4h-ddr3-20260802T001440Z
```

List all configuration-driven runs:

```bash
run/run list
```

`run/run ls` is an alias for `list`.

Read the last 80 or 200 log lines:

```bash
run/run log latest
run/run log linux-smp-4h-ddr3-20260802T001440Z 200
```

Follow build and simulation output:

```bash
run/run tail latest
run/run follow linux-smp-4h-ddr3-20260802T001440Z 200
```

`tail` and its `follow` alias use `tail -F` so log replacement or delayed
creation does not silently detach the reader.

Attach to an active run's tmux session:

```bash
run/run attach latest
```

Inside tmux, `attach` switches the current client. Outside tmux, it attaches
normally. It rejects finished or lost runs.

Print the resolved directory, checkpoints, or recorded launch and simulator
commands:

```bash
run/run path latest
run/run checkpoint latest
run/run command latest
```

Wait for completion and print final status:

```bash
run/run wait latest
```

Request a scoped stop of the newest run:

```bash
run/run stop latest
```

`stop` sends `Ctrl-C` to that run's recorded tmux session. It does not delete
the run directory or reuse its name. The worker records the interrupted exit
when it handles the signal.

The lifecycle state reported by `status` is:

- `active`: the recorded tmux session exists;
- `finished`: the session is gone and a final `status` file exists;
- `lost`: neither an active session nor a final status record can be found.

`latest` means the most recently created managed record under `run/log/`,
selected by `manager.env` modification time. Legacy records under
`build/runs/` are not included.

## Boot validation

Process completion alone is not Linux-boot success. The SMP backend classifies
the run as:

- `pass`: `run.log` contains both the literal `openrv64# ` shell prompt and a
  testbench `PASS` marker;
- `fatal`: a Verilator fatal or assertion failure was recorded;
- `panic`: a Linux panic marker was recorded;
- `checkpoint`: a requested `--checkpoint-exit` completed successfully;
- `stopped`: a requested `--stop-cycles` boundary was reached successfully;
- `simulator-error`: the simulator exited nonzero without a stronger recorded
  classification;
- `incomplete`: the simulator exited zero without the prompt-and-PASS proof;
- `not-run`: failure occurred before simulation.

An incomplete cycle-limited run is evidence only up to its last signpost. It
must not be reported as a successful boot. Likewise, a notification is
best-effort convenience, not validation; use `status` and the retained logs.

## Adding a configuration

For a new durable variant:

1. Copy the nearest file in `run/cfg/` to a descriptive new filename.
2. Keep `RUN_CONFIG_VERSION=1` and select a supported `RUN_TARGET`.
3. Change every hardware or software value that defines the target in the
   file, rather than hiding it in a launch alias or tmux command.
4. Keep `RUN_DESCRIPTION` specific enough to explain the comparison.
5. Make the file executable.
6. Run `bash -n run/cfg/<name>.cfg` before launch.
7. Invoke the configuration itself and use the generated run directory for
   all reported evidence.

Example:

```bash
cp run/cfg/linux-smp-4h-ddr3.cfg \
    run/cfg/linux-smp-4h-ddr3-swizzle1.cfg
chmod +x run/cfg/linux-smp-4h-ddr3-swizzle1.cfg
# Edit OPENSBI_4H_DDR3_BANK_ROW_SWIZZLE to 1 and update RUN_DESCRIPTION.
bash -n run/cfg/linux-smp-4h-ddr3-swizzle1.cfg
run/cfg/linux-smp-4h-ddr3-swizzle1.cfg
```

Do not edit a snapshotted `run/log/.../run.cfg` to describe a different run.
It is evidence, not an input for retroactive relabeling.
