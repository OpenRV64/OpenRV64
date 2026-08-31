# OpenRV64 architectural checks

This directory contains first-party local smoke programs and test harnesses.
They verify basic execution and the architectural trace contract; they are not
the RISC-V Architectural Tests and do not establish RISC-V certification.

## Local targets

The local smoke exercises the 1-pipe, native 3-pipe, platform-1-pipe, and
platform-3-pipe harnesses:

```sh
make compliance-smoke-local
```

The trace-contract target runs the local ELF on the direct backends and checks
retirement ordering, lane, field width, privilege mode, and instruction
alignment:

```sh
make compliance-trace-contract
```

`make compliance-full` currently combines those two local checks. It does not
run an external architectural suite.

## ACT4 status

ACT4 and Sail are external dependencies and are not vendored here. The previous
OpenRV64 ACT4 adapter contained modified files derived from upstream examples.
It was removed on 2026-08-07 pending a clean reimplementation with explicit
provenance, notices, and licensing. The Make targets that generated or ran ACT4
were removed with it.

This is a provenance problem in the former adapter, not a claim that ACT4 is
GPL-2.0. Do not describe the local smoke targets as ACT4 coverage.

Historical runs on 2026-07-22 used `riscv/riscv-arch-test` branch `act4` at
commit `619aa16960e69ac29e9b558fb907babfb937a090` and `sail_riscv_sim` 0.12.
They recorded 93 passing unprivileged tests on the platform and native 3-pipe
backends, plus three passing Svbare tests on the platform. Those results are
historical evidence only: the current repository cannot reproduce them without
a new adapter, and they are not a blanket ISA or certification claim.

The generic runner can still execute self-checking ELFs produced entirely in an
external checkout:

```sh
python3 tools/compliance.py suite /path/to/external/elfs \
  --backend platform --results-dir build/compliance/external-results
```

The conservative banked 3-pipe backend is selected explicitly with
`--backend 3p-banked` for the direct cacheless harness, or with
`--backend platform-3p-banked-ddr3` for the one-hart integrated L2 and
timed-DDR3 platform.  Each uses a separate simulator artifact so it cannot
silently reuse the normal 3-pipe elaboration.

When the preserved ACT4 work products are present under the ignored
`build/compliance/act4-work` tree, `make compliance-act4-3p-banked` runs the
RV64IMA ELF set through the direct backend.  The preferred banked platform
run, matching the timed-memory structure used by the Linux simulations, is:

```sh
run/run run/cfg/compliance-act4-platform-3p-banked-ddr3.cfg
```

The corresponding current-3P control is
`run/cfg/compliance-act4-platform-3p-ddr3.cfg`.  Both platform harnesses reject
a nominal pass unless the timed-DDR3 endpoint accepted a read command.  These
targets do not regenerate or validate the provenance of the preserved
external-suite binaries.

Sail differential testing remains available when both the simulator and its
configuration are supplied externally:

```sh
python3 tools/compliance.py diff /path/to/test.elf \
  --backend 1p --sail /path/to/sail_riscv_sim \
  --sail-config /path/to/sail.json
```

A replacement ACT4 integration must keep the upstream checkout outside tracked
source, generate work products under ignored `build/`, and document the origin
and license of every adapter file.
