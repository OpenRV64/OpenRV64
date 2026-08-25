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

## FPGA approval gate

Read-only inspection of FPGA files and artifacts is allowed without approval.

Before making an FPGA-related mutation, stop and request explicit approval for
that individual change. Approval is single-use and applies only to the exact
change described. It does not authorize adjacent cleanup, follow-up fixes,
documentation changes, additional tests, or another FPGA change.

Separate approval is required for each change involving:

- FPGA RTL, boot firmware, board wrappers, or FPGA build configuration;
- cycle breakpoints, cycle-counted state transitions, pipeline boundaries,
  BRAM latency, CDC stages, reset delays, timeouts, or other cycle-valued
  behavior;
- clocks, frequencies, multipliers, dividers, or generated-clock behavior;
- XDC clocks, input/output delays, false paths, or multicycle paths;
- synthesis, implementation, bitstream generation, programming, or direct
  hardware operations that are not launched through `run/run`.

Present multiple proposed FPGA changes as separately lettered approval items.
Only perform the items the user explicitly approves.

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
approval rule to match. This exception authorizes only the managed `run/run`
operation; it does not authorize FPGA source changes.

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
