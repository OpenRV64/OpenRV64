# Linux userspace SMP stress

`openrv64_user_stress` is a short, deterministic RV64IMA userspace suite for
the coherent Linux configuration.  It is freestanding: it uses Linux syscalls,
raw `clone()` threads, and GCC atomics without libc or TLS.

The quick suite covers:

- pinned workers executing concurrently on every available CPU;
- atomic fetch-add and CAS/LR-SC turn handoff;
- a ticket lock with a non-atomic protected payload;
- independent cache lines within one page, page-spaced private lanes, false
  sharing, and same-line ownership handoff;
- two `MAP_SHARED` virtual aliases of one memfd page, with atomic and ordered
  handoffs through different VAs;
- a remote-core TLB invalidation test that repeatedly warms a writable mapping
  on CPU 1, changes permissions on CPU 0, moves it with `mremap(MREMAP_FIXED)`,
  and immediately installs a different page at the old VA;
- a contended futex-backed mutex when the kernel implements `futex(2)`.

Build and install the freestanding binary and runner in `sw/initramfs/`:

```sh
make sw-linux-user-tests
```

`make sw-smp-thread-probe` also installs this suite.  The existing
`/bin/smp-thread-test` boot script runs quick mode after its original raw-clone
affinity probe; the init script still proceeds to the shell after reporting a
test failure.

After rebuilding the Linux `Image` that embeds `sw/initramfs`, run:

```sh
/bin/openrv64-user-tests --quick
/bin/openrv64-user-tests --full
```

Quick mode is suitable for RTL Linux boots.  Full mode raises iteration counts
for FPGA or faster-model soak testing.  A PASS proves the checked outcomes and
forward progress for that run; it is not an architectural litmus proof and is
not a substitute for prolonged randomized stress.

## Pthread constraint

`pthread_lock_stress.c` is the real pthread mutex portion.  It is intentionally
not built by the default target today.  The current OpenRV64 Linux `.config`
has `CONFIG_FUTEX` disabled, while the installed generic RISC-V glibc is
RV64GC/lp64d.  Linking that libc into an RV64IMA-only test would silently add
unsupported ISA/ABI requirements.  To run the pthread test, first provide a
static RV64IMA/lp64 pthread libc and enable `CONFIG_FUTEX`; then compile the
source as `/bin/pthread_lock_stress`, for example:

```sh
make RISCV_LINUX_PTHREAD_CC=/path/to/riscv64-linux-musl-gcc \
	RISCV_LINUX_PTHREAD_SYSROOT=/path/to/rv64ima-musl-sysroot \
    sw-linux-user-pthread-test
```

The suite runner detects the binary and runs it automatically, otherwise it
reports a specific SKIP.  Check the resulting ELF attributes; naming a compiler
is not proof that its static libc is RV64IMA/lp64.
