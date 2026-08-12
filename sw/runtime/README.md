# Freestanding single-hart runtimes

`bare.S` and `sv39.S` give assembly or C workloads the same entry contract:

```c
void c_init(void);       /* optional; weak no-op default */
uint64_t main(void);     /* required; return value is left in a0 */
```

Both runtimes initialize `gp`, `sp`, and `tp`, clear the linker-defined BSS,
call `c_init()`, and then call `main()`. Returning from `main()` terminates with
an `EBREAK` and preserves its return value for the testbench.

Memory-state microbenchmarks can compile the runtime with
`-DOPENRV64_RUNTIME_NO_BSS_CLEAR`. This retains register initialization and the
`c_init()`/`main()` chain without touching a cold destination or working set
before the workload starts. It is not appropriate for ordinary C programs
that rely on zero-initialized static storage.

Use the bare runtime with the existing linker script:

```text
riscv64-elf-gcc ... -T sw/openrv64.ld \
    sw/runtime/bare.S workload.c
```

Use the Sv39 runtime with its matching linker script:

```text
riscv64-elf-gcc ... -T sw/runtime/openrv64-sv39.ld \
    sw/runtime/sv39.S workload.c
```

The Sv39 runtime enters at physical `0x80000000`, grants S-mode access to a
16 MiB PMP RAM aperture, enables `cycle` and `instret`, installs three-level
page tables, and enters S-mode at virtual `0x40001000`. The standard mapping
is a deliberately non-identity 256 KiB window:

```text
VA 0x40000000-0x4003ffff -> PA 0x80000000-0x8003ffff
```

The workload image, BSS, and stack must fit that window. Workloads needing
device mappings, scattered pages, multiple harts, or a larger virtual layout
still need a specialized linker/table policy, but they can reuse the C-entry
contract.

## Migrated workloads

The shared entry path is used by the single-hart BLAKE2s, CoreMark loop,
atomic, memcpy, STREAM, stride, stencil, instruction-cache, LZ4, page-free,
pointer-chase, speculation, store-extension, floating-point, and fence
microbenchmarks. Bare builds use `bare.S`; translated builds use `sv39.S` and
`openrv64-sv39.ld` where their address-space requirements fit the standard
mapping. Assembly payloads may retain their existing terminal `EBREAK`
instead of returning from `main()`.

The following classes deliberately keep specialized startup:

- multi-hart tests, which own per-hart stacks, barriers, boot elections, or
  trap state;
- fence correctness tests, which require device mappings and checker-visible
  fixed sections;
- the non-contiguous zero benchmark, which requires a scattered page map and
  a separately seeded physical image;
- exception, interrupt, OpenSBI, Linux, UART, and vector tests, which own trap
  routing, firmware/process entry, platform setup, or a private memory ABI.

These are policy differences, not candidates for blindly replacing with the
standard single-hart runtime.
