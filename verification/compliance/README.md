# OpenRV64 architectural compliance

This directory contains the OpenRV64 adapter for the ACT4 branch of the
official RISC-V Architectural Tests. It is deliberately separate from the
module-level RTL tests: an ACT4 ELF is self-checking, runs on a complete DUT
configuration, and passes only by writing the value `1` to its `tohost`
symbol.

The default unprivileged set is:

```text
I,M,Zaamo,Zalrsc,Zicsr,Zifencei
```

The initial privileged set is `Svbare`. The machine descriptions cover the
RV64IA and RV64IMA configurations, M/S/U privilege modes, Sv39/Svade/Svbare,
the platform memory map, and the implemented CSR/PMP parameters.

## Prerequisites

Local smoke tests require Python 3, Icarus Verilog, GNU Make, and an RV64 GNU
bare-metal toolchain (`riscv64-elf-gcc`, `riscv64-elf-nm`). Native 3-pipe
suite runs use Verilator when it is available. ACT4 additionally requires its
Python/Ruby/UDB environment and a Sail RISC-V simulator.

The adapter was validated against these exact external versions:

- `riscv/riscv-arch-test`, branch `act4`, commit
  `619aa16960e69ac29e9b558fb907babfb937a090`
- `sail_riscv_sim` version `0.12`

The external projects are not vendored. One reproducible ACT4 setup is:

```sh
git clone --branch act4 https://github.com/riscv/riscv-arch-test.git
git -C riscv-arch-test checkout 619aa16960e69ac29e9b558fb907babfb937a090
mise trust riscv-arch-test/.mise.toml

export ACT4_ROOT="$PWD/riscv-arch-test"
export SAIL_RISCV=/path/to/sail_riscv_sim
```

ACT4 documents alternatives to `mise`, including `uv` plus Ruby/Bundler. Check
the complete local and external tool state with:

```sh
python3 tools/compliance.py doctor \
  --act4-root "$ACT4_ROOT" --sail "$SAIL_RISCV" --strict
```

## Targets

The local smoke is dependency-light and exercises all three harnesses:

```sh
make compliance-smoke-local
```

The Sail differential check compares the local no-trap program's retired PC,
instruction, and GPR writes on both direct core paths:

```sh
make compliance-diff SAIL_RISCV="$SAIL_RISCV"
```

The trace-contract target executes the same ELF on 1-pipe, native 3-pipe, and
platform backends, then checks ordering, lane, field-width, privilege-mode,
and instruction-alignment invariants:

```sh
make compliance-trace-contract
```

Generate and run the configured official suites with:

```sh
make compliance-isa \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"

make compliance-isa-3p \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"

make compliance-priv \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"
```

`compliance-isa` is the canonical result: it uses the integrated platform with
boot ROM, RAM, CLINT, PLIC, UART, GPIO, and timer. The native 3-pipe target
validates the 256-bit AXI/CCX memory path; it acknowledges ACT4 setup MMIO as
inert and must not be used as evidence for interrupt or peripheral behavior.
The direct 1-pipe harness is intentionally limited to local and differential
tests because ACT4's common prologue accesses CLINT state.

The runner's default `--engine auto` policy uses Icarus for 1-pipe/platform
and Verilator for 3-pipe, falling back to Icarus if Verilator is unavailable.
Either engine can be forced across a Make target:

```sh
make compliance-isa-3p COMPLIANCE_ENGINE=iverilog \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"

make compliance-isa COMPLIANCE_ENGINE=verilator \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"
```

Both engines execute the same SystemVerilog harness and consume the same ELF
image. The selected engine is recorded in every `result.json`. On the
validation machine, Verilator reduced the 3-pipe `I-add` test from about
33.0 seconds to 0.169 seconds after the one-time C++ build.

Run every configured lane with:

```sh
make compliance-full \
  ACT4_ROOT="$ACT4_ROOT" SAIL_RISCV="$SAIL_RISCV"
```

Override `COMPLIANCE_EXTENSIONS` or `COMPLIANCE_PRIV_EXTENSIONS` to select a
different generated set. The runner filters the execution set by the requested
extension directories, so ELFs left by an earlier generation cannot silently
expand a later run.

## Results and failure policy

Artifacts are under `build/compliance/`:

- ACT4-generated ELFs under `act4-work/<config>/elfs/`;
- one `run.log` and `result.json` per ELF;
- an optional `arch.csv` retirement trace;
- a JSON summary and JUnit XML report for each suite.

Simulation has both a cycle limit and a wall-clock timeout. A zero simulator
exit code alone is insufficient: the log must contain `COMPLIANCE PASS`, which
is emitted only for `tohost == 1`. Any other nonzero `tohost` value is a test
failure.

Known failures belong in `verification/compliance/expected_failures.tsv` as:

```text
exact-elf-stem<TAB>specific reason
```

There are no broad wildcard skips. An expected failure that starts passing is
reported as XPASS and fails the suite, forcing the ledger to be cleaned up.
The ledger is currently empty.

## Validation snapshot

On 2026-07-22, with the pinned versions above:

- local 1-pipe, native 3-pipe, and platform smokes passed;
- Sail differential comparison passed for 16 retired 1-pipe instructions and
  15 retired 3-pipe instructions;
- ACT4 generated 93 unprivileged ELFs: 51 I, 13 M, 18 Zaamo, 4 Zalrsc,
  6 Zicsr, and 1 Zifencei;
- all 93 unprivileged ELFs passed on the integrated platform backend;
- all 93 unprivileged ELFs passed on the native 3-pipe AXI/CCX backend;
- all three generated Svbare ELFs passed on the platform backend.

This is evidence for the listed executions, not a blanket RISC-V certification
claim. The full 3-pipe run initially exposed incorrect same-cycle `instret`
ordering in four CSR tests; forwarding architecturally older retirement into
the CSR read fixed the defect, after which all four passed under both Icarus
and Verilator and both 93-test suites passed without expected failures.

## Deliberate boundaries

- The upstream ACT4 default exclusion for `Sm` remains in force because ACT4
  identifies insufficient WARL configuration support for that group.
- The platform currently has no supervisor external/software interrupt
  injection path. ACT4 requires those model macros to exist, so they are empty;
  a test that requires them will fail at runtime rather than being falsely
  reported as supported.
- UDB permits visible PMP counts of 0, 16, or 64. The configuration declares
  16 entries with 8 usable because OpenRV64 implements eight writable entries.
- The CSV retirement contract and Sail comparison are executable checks, but
  they are not a full RVFI proof. The current trace lacks source-register data
  and architectural memory address/mask/data fields required for general
  riscv-formal checking.
- No OOO backend is claimed here. An OOO implementation should use an FPGA
  execution adapter once RTL simulation is no longer operationally useful,
  while preserving the same ELF, `tohost`, timeout, JSON/JUnit, and exact-xfail
  contracts so hardware and simulation results remain comparable.
