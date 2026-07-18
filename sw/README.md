# Bare-metal software

`uart.c` is a freestanding RV64I/Zicsr platform test linked into the 16 MiB
RAM window at `0x8000_0000`. The boot ROM transfers control there after reset.

The firmware configures the 16550-compatible UART for divisor 1, routes UART
source ID 1 through the PLIC, and arms a CLINT machine-timer deadline. UART RX
and TX are serviced only from machine external interrupts. A newline ends the
input line; carriage return immediately before it is stripped.

Given:

```text
codex\n
```

the serial output is:

```text
hello codex\n
```

If no complete line arrives within 4096 `mtime` ticks, the machine-timer ISR
cancels the deadline and the interrupt-driven UART transmits `timeout\n`.

Build the ELF and flat image with:

```sh
make sw-uart
```

Run both the successful-input and timeout boots against the integrated
platform with:

```sh
make sim-uart-firmware
```

The toolchain prefix can be overridden with `RISCV_CC` and
`RISCV_OBJCOPY`. The default is Arch Linux's `riscv64-elf-*` toolchain.

## OpenSBI smoke boot

`tools/build-opensbi.sh` clones the pinned OpenSBI v1.9 release, verifies its
commit, and builds the generic FDT platform plus a RAM-resident trampoline and
S-mode smoke payload. OpenSBI requires a PIE-capable toolchain, so its default
prefix is `riscv64-linux-gnu-`; the two small bare-metal stages continue to use
`riscv64-elf-*`. The other build dependencies are Git, GNU Make, DTC, Python,
and Verilator.

The RAM image layout is:

```text
0x8000_0000  reset-ROM target and RAM trampoline
0x8010_0000  OpenSBI fw_jump
0x8020_0000  S-mode SBI smoke payload
0x80e0_0000  testbench completion word
0x80f0_0000  flattened device tree
```

The ROM remains a policy-free jump to `0x8000_0000`; the trampoline supplies
the OpenSBI entry registers and jumps to fw_jump. The build script forces
OpenSBI-generated linker inputs to refresh, checks the linked entry address,
and writes bounded memory fragments under `build/opensbi/artifacts/`.

Build only the artifacts with:

```sh
make opensbi
```

Run the integrated platform test with:

```sh
make sim-opensbi
```

The test uses Verilator by default and proves the OpenSBI banner, eight-entry
PMP isolation setup, M-to-S transition, SBI base ECALL, debug-console output,
and payload completion. `make sim-opensbi-icarus` provides a much slower
Icarus path. Set `OPENSBI_DEBUG=1` only when an unoptimized OpenSBI build is
intentional; the script ignores an unrelated ambient `DEBUG` variable.
