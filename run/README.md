# Run configurations

`run/cfg/` contains named, executable configurations for long-running targets.
Invoke a configuration directly:

```sh
run/cfg/linux-smp-4h-ddr3.cfg
```

or pass it to the common runner:

```sh
run/run linux-smp-4h-ddr3
run/run run/cfg/linux-smp-4h-ddr3.cfg --rebuild
run/run linux-smp-4h-user-tests-ddr3 --rebuild
```

`linux-smp-4h-user-tests-ddr3` uses the separately built
`sw/Image.smp-user-tests`.  Its initramfs runs the short Linux userspace SMP,
atomic, cache-coherence, VA-alias, and remote-remap tests before opening the
interactive shell.  The ordinary SMP configurations continue to use
`sw/Image.smp`.

Each launch creates `run/log/<configuration-name>-<UTC timestamp>/`. The
directory is self-contained: it records the selected configuration, effective
Make values, source hashes, repository state, build and simulation logs,
snapshotted inputs and executable, checkpoint, and final validation status.

Manage generated runs with:

```sh
./run/run.sh status latest
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

`./run/run.sh status INSTANCE` reads the managed heartbeat, completion record,
checkpoint, and latest simulator progress directly. It does not query tmux or
the host process table, so it also works from a restricted PID namespace. An
exact timestamped run ID or a configuration-name prefix selects an instance.

`log` prints a finite suffix. `tail`/`follow` follows the build and simulation
logs. `attach` switches to the run when invoked inside tmux and attaches
normally outside tmux. `wait` blocks until the run's session ends and then
prints its final status.

Common start controls are:

```sh
run/cfg/linux-smp-4h-ddr3.cfg --max-cycles 80000000
run/cfg/linux-smp-4h-ddr3.cfg --checkpoint 18000000
run/cfg/linux-smp-4h-ddr3.cfg --checkpoint 18000000 --checkpoint-exit
run/cfg/linux-smp-4h-ddr3.cfg --resume RUN_OR_CHECKPOINT
run/cfg/linux-smp-4h-ddr3.cfg --resume RUN_OR_CHECKPOINT \
    --stop-cycles 35000000
```

Resume copies the source run's checkpoint, exact snapshotted simulator, and
inputs into a new timestamped record. It does not rebuild current RTL against
old serialized state. Unless a new `--checkpoint` is explicitly supplied,
resume disables the configuration's normal checkpoint.

Configurations may set `RUN_KERNEL_ELF` to the `vmlinux` matching
`RUN_IMAGE`. The runner verifies its `arch/riscv/boot/Image` byte-for-byte,
snapshots the ELF, generates Linux and OpenSBI symbol maps, and passes them to
the simulator. Million-cycle progress then has a companion line such as:

```text
OPENSBI_4H_PC_SYMBOLS cycles=55000000 harts=linux:memcpy+0x8,<reset>,<reset>,<reset>
```

Raw PCs remain in `OPENSBI_4H_PROGRESS`. Harts held in reset are explicitly
printed as `<reset>` rather than symbolizing their zero PC.

`tools/run-linux-smp.sh` remains the target-specific backend. New automation
should call a configuration rather than construct backend arguments directly.
