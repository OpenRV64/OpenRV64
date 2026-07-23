# Bare-metal software

`uart.c` is a freestanding RV64I/Zicsr platform test linked into the 256 MiB
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

## memcpy prefetch benchmark

`memcpy/memcpy.S` supplies 4 KiB and 64 KiB page-copy workloads for the
three-pipe native L1D/CCX path. Each loop iteration copies one aligned 64-byte
cache line. The source is already present in the load image, so source
generation does not warm the data cache before measurement.

Build both images and their disassemblies with:

```sh
make sw-memcpy
```

Run only the timed copy regions with:

```sh
make bench-memcpy
```

The benchmark stops at `memcpy_measure_end`; `a0` in the `PERF` line is the
copy's `mcycle` delta through the final ordering fence. It measures
software-visible completion; a posted lower-level store tail can still drain
afterward, as it can after a normal `memcpy` return. Run the
post-copy full comparison and require the `MEMCPYOK` result with:

```sh
make sim-memcpy
```

The individual targets are `bench-memcpy-4k`, `bench-memcpy-64k`,
`sim-memcpy-4k`, and `sim-memcpy-64k`. The AXI harness's
`AXI_3P_FREE_L1I_REFILLS` and `AXI_3P_FREE_L1D_REFILLS` controls can be used
to establish separate ideal-refill bounds. Its backing RAM is still a
functional fixed-latency model, not a DRAM timing model; prefetch distance and
bandwidth tuning require the memory-channel timing model in the measured path.

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
0x8ff0_0000  flattened device tree
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

Run the same boot contract on the fixed three-pipe baseline, including its
three-wide frontend and native 256-bit AXI RAM path, with:

```sh
make sim-opensbi-3p
```

The test uses Verilator by default and proves the OpenSBI banner, eight-entry
PMP isolation setup, M-to-S transition, SBI base and TIME ECALLs, machine-mode
STIP injection, a delegated S-mode timer trap, debug-console output, and payload
completion. The device tree advertises Svade and 256 MiB of RAM.
`make sim-opensbi-icarus` provides a much slower
Icarus path. Set `OPENSBI_DEBUG=1` only when an unoptimized OpenSBI build is
intentional; the script ignores an unrelated ambient `DEBUG` variable.
