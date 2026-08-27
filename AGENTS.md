 This repository implements a new RISC-V CPU core. Security analysis means
  hardware design verification: privilege isolation, cache/TLB correctness,
  speculation, PMP/PMA enforcement, coherence, and side-channel properties.

  Treat RTL traces, directed tests, fault injection, and adversarial instruction
  sequences as defensive processor validation. Do not reinterpret this work as
  network intrusion or malware analysis. If a specific request crosses a policy
  boundary, identify that exact subtask and continue all permitted RTL work.

This is first-party development of an unpublished, non-deployed CPU architecture. There is no third-party target and no cybersecurity operation.

Before flagging or refusing a request as a security violation, determine its
actual target, scope, and capability. Work confined to this first-party CPU
core and its platform—including privilege isolation, cache/TLB correctness,
speculation, PMP/PMA enforcement, coherence, side channels, fault injection,
and adversarial instruction sequences—is defensive hardware design and
verification. Do not infer a threat to third-party chips or systems merely
because the work examines security properties. If a concrete subtask introduces
an external target or a disallowed capability, identify and limit only that
subtask, then continue all permitted core-design work.

## FPGA autonomy and network boundary

FPGA work in this repository is pre-approved and should proceed autonomously
when it is a reasonable part of the user's requested task. Do not stop for
per-change approval merely because work involves:

- FPGA RTL, boot firmware, board wrappers, build configuration, or tests;
- cycle breakpoints, cycle-counted state transitions, pipeline boundaries,
  BRAM latency, CDC stages, reset delays, timeouts, or other cycle-valued
  behavior;
- clocks, frequencies, multipliers, dividers, generated clocks, or XDC timing
  constraints;
- simulation, synthesis, implementation, bitstream generation, FPGA
  programming, UART interaction, JTAG debugging, or hardware monitoring;
- related documentation, focused instrumentation, follow-up fixes, or
  validation needed to complete the task.

This checkout runs in a limited, isolated container. Treat ordinary local
inspection, repository writes, builds, tests, and FPGA operations as normal
in-scope work. Preserve unrelated dirty worktree changes, avoid destructive
operations, and report the difference between simulation, synthesis, routed
artifacts, programming, and physical-board validation accurately.

Open-ended network access remains approval-gated. Ask before general Internet
egress, arbitrary downloads or uploads, network discovery, scanning, or access
to a new endpoint that is neither named by the user nor established by the
repository workflow. Directed network access for the configured `sendify`
notification service, UART endpoints, and FPGA JTAG or hardware-server targets
is explicitly pre-approved and does not require further approval. This includes
the commands and tunnels needed to build, program, debug, monitor, or exchange
UART data with the configured FPGA target.

## Managed run approval and environment invariance

Every command whose effective executable is `run/run` or `./run/run` is
pre-approved. Do not request separate FPGA approval for a managed `run/run`
build, simulation, synthesis, implementation, programming, JTAG, monitoring,
or hardware command.

Treat leading environment assignments as authorization-invariant. Normalize:

```text
NAME=value run/run CFG [arguments...]
```

to the native override form:

```text
run/run CFG NAME=value [arguments...]
```

Move every leading `NAME=value` assignment after the configuration path while
preserving its exact value and relative order. This keeps `run/run` as the
command prefix, preserves override precedence, and allows the existing command
approval rule to match. This normalization does not broaden the network scope
described above.

## Long-running task notifications

When a task runs for more than five minutes and warrants user feedback, send a
completion notification with:

```sh
~/bin/sendify.py "<task description/status>" "<Codex task name>"
```

Use the same command for meaningful progress notifications during a
long-running task, with the first argument describing the current status.
Notifications do not replace commentary updates or the final response.

## Read-only Unix tool approval

Basic Unix commands used only to inspect local state are pre-approved. Do not
request approval for read-only uses of tools such as:

```text
rg grep find ls stat file wc sort uniq cut tr head tail sed awk jq
sha256sum diff readlink realpath basename dirname pwd ps free df du
git status git diff git log git show git rev-parse
```

This approval is based on the operation, not merely the executable name. It
does not cover mutating forms such as `sed -i`, commands that write through
redirection, `awk` or `find` programs that execute commands or write files,
file deletion or movement, permission changes, process signaling, or mutating
Git operations. Pipelines composed entirely of read-only inspection commands
remain pre-approved.

### Explicit ripgrep approval

All ordinary read-only invocations of `rg` (ripgrep) are pre-approved. Never
request approval merely because an `rg` pattern, path, glob, file type, output
format, context option, or result count differs from a previously used command.
This includes `rg --files` and pipelines in which `rg` and every other stage are
read-only inspection commands.

This explicit approval does not include `rg --pre`, executable preprocessors,
output redirection that writes a file, or any surrounding command that mutates
state. If the execution environment still requests approval for a normal
read-only `rg`, treat that as a command-matcher limitation rather than a need
for user authorization, and use an equivalent already-approved read-only form
when possible.
