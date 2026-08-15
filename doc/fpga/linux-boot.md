# MYD-J7A100T Linux boot

Status date: 2026-08-15 UTC

This procedure booted Linux on the physical MYIR MYD-J7A100T. It is a
single-hart bring-up path: a hardware UART loader populates DDR3 while the CPU
is held in reset, verifies the complete image with CRC32, and then releases the
core into OpenSBI.

The successful physical result required all of these markers, including the
literal shell prompt:

```text
OPENRV64 DDR LOAD PASS
OPENRV64 FPGA BOOT PASS
OpenSBI v1.9
Linux version 7.2.0-rc4+
OPENRV64 BUSYBOX INIT
openrv64#
```

An init banner alone is not a boot PASS.

## Validated configuration

- Board: MYIR MYD-J7A100T / MYC-J7A100T-32Q512D-I
- FPGA: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Core: one hart, one-pipe backend
- Core, UART, and timebase clock: 9.216 MHz
- MIG UI and pre-boot loader clock: 100 MHz
- DRAM: 256 MiB at `0x80000000`
- Generic unified TLB: four entries
- Optional PTW non-leaf PTE cache: disabled
- UART: 115200 baud, 8 data bits, no parity, one stop bit
- OpenSBI: v1.9, commit
  `cbf9f6734dd85a982c63e3cb5db7ffe09da839ca`
- Linux: 7.2.0-rc4+ with an embedded BusyBox initramfs

Memory layout:

| Address | Contents |
| --- | --- |
| `0x80000000` | 32-byte reset trampoline |
| `0x80100000` | OpenSBI `fw_jump` |
| `0x80200000` | Raw Linux Image |
| `0x8ff00000` | Flattened device tree |

The DT describes 256 MiB of RAM. OpenSBI reserves its machine-mode regions
before entering Linux at `0x80200000` in S-mode with the FDT address in `a1`.

## Boot architecture

The fixed FPGA loader first copies the trampoline, OpenSBI, small payload slot,
and FDT from FPGA ROMs into DDR3. The CPU remains in reset. The hardware loader
then performs this sequence:

1. Wait for MIG calibration and fixed-image completion.
2. Emit `OPENRV64 DDR LOAD READY`.
3. Scan UART RX for a valid 16-byte transfer header.
4. Emit `OPENRV64 DDR LOAD START`.
5. Receive the raw Linux Image and write aligned 32-byte lines through the
   native 256-bit MIG application port.
6. Mask unused bytes in the final partial line.
7. Compare the received IEEE CRC32 with the header.
8. Emit `OPENRV64 DDR LOAD PASS`; the integrated boot-status block then emits
   `OPENRV64 FPGA BOOT PASS` and releases the CPU after both messages finish.
   On a CRC mismatch, emit `OPENRV64 DDR LOAD CRC FAIL` and keep the CPU in
   reset.

The transfer header is:

| Offset | Size | Encoding |
| --- | ---: | --- |
| 0 | 8 | ASCII `ORV64LNX` |
| 8 | 4 | Image length, little-endian unsigned 32-bit |
| 12 | 4 | IEEE CRC32, little-endian unsigned 32-bit |

The payload immediately follows the header. There are no per-block
acknowledgements. The final CRC marker is the end-to-end completion barrier.
The hardware accepts lengths from 4 bytes through `0x0fd00000`, requires a
multiple of four bytes, and prevents the image from reaching the FDT at
`0x8ff00000`. The host tool additionally checks the RISC-V Linux Image magic
at file offset `0x38`.

Relevant implementation files:

- `synth/fpga/xc7a100t/uart_ddr_loader.sv`
- `synth/fpga/xc7a100t/opensbi_system.sv`
- `synth/fpga/xc7a100t/ddr3_boot_loader.sv`
- `synth/fpga/xc7a100t/mig_scalar_bridge.sv`
- `tools/fpga-uart-linux-load.py`

## Validated artifacts

The build directory is ignored by Git. Preserve and verify the bitstream
separately.

Bitstream:

```text
build/fpga/xc7a100t/linux-hw-preload-tlb4/
  openrv64_myd_j7a100t_linux_hw_preload.bit
```

- Size: 3,826,012 bytes
- SHA-256:
  `a957d2f1d1069dfb8a1e68f43101ecf8dd04942920e5b59fc709957e8b4930f8`

Linux input:

```text
sw/Image.Zicclsm
```

- Size: 5,021,332 bytes
- SHA-256:
  `6d7071598d68d66199ea96834538cf95b51aaa45550d6dd871c0ba1c66a450ba`
- CRC32: `8836c071`

Verify both inputs before reproducing the recorded result:

```sh
sha256sum \
  build/fpga/xc7a100t/linux-hw-preload-tlb4/openrv64_myd_j7a100t_linux_hw_preload.bit \
  sw/Image.Zicclsm
```

The recorded build used source commit
`aa21215f24c61b462f2b16696f493bcfb41ea27b` on branch
`aj/zbb-blake2s`, plus uncommitted changes captured in the run record.

## Program the FPGA

Start UART capture before programming so that early calibration and loader
messages are not lost. The programming host must run `hw_server`, and the
Vivado host must be able to reach it on TCP port 3121.

Program volatile FPGA SRAM only:

```sh
/home/bill/bin/vivado -mode batch \
  -source synth/fpga/xc7a100t/program_bitstream.tcl \
  -tclargs TCP:<hw-server-host>:3121 \
  build/fpga/xc7a100t/linux-hw-preload-tlb4/openrv64_myd_j7a100t_linux_hw_preload.bit
```

The script requires exactly one JTAG target and exactly one detected
`xc7a100t`. Stop if either check fails. Successful programming must report FPGA
startup HIGH and `OPENRV64 FPGA PROGRAM PASS`.

This command does not write SPI configuration flash.

## Provide the UART bridge

The loader command expects a bidirectional raw PTY at `/tmp/ttyACM0`. In the
validated setup, socat and SSH connected that PTY to the board's physical USB
UART. The exact remote-side command is environment-specific and is not
recorded here; do not invent it from this document.

Before loading, verify that the path exists and is connected to the current
socat session:

```sh
ls -l /tmp/ttyACM0
stty -F /tmp/ttyACM0 -a
```

Do not run another terminal program against the PTY while the image loader is
active.

## Load and boot Linux

Run:

```sh
/home/bill/.venv/bin/python tools/fpga-uart-linux-load.py \
  --device /tmp/ttyACM0 \
  --ready-timeout 120 \
  --boot-timeout 7200 \
  --hardware-preload \
  sw/Image.Zicclsm
```

For the validated 5,021,332-byte image, the absolute minimum 115200-baud wire
time is 435.9 seconds. Host-side messages saying that bytes were queued or that
the local PTY drained do not prove that the physical UART has finished. Keep
the process and SSH/socat channel open until the FPGA emits either
`OPENRV64 DDR LOAD PASS` or `OPENRV64 DDR LOAD CRC FAIL`.

After CRC PASS, the expected sequence is:

```text
OPENRV64 FPGA BOOT PASS

OpenSBI v1.9
...
Domain0 Next Address        : 0x0000000080200000
Domain0 Next Arg1           : 0x000000008ff00000
Domain0 Next Mode           : S-mode
...
Linux version 7.2.0-rc4+
...
OPENRV64 BUSYBOX INIT
/bin/sh: can't access tty; job control turned off
openrv64#
```

The job-control warning is expected for this initramfs console. It did not
prevent shell use.

## Recorded physical result

On 2026-08-15, the physical board produced all required markers. Linux
reported:

- machine model `OpenRV64 single-hart platform`;
- 251,216 KiB available from 256 MiB;
- the RISC-V clocksource at 9.216 MHz;
- a 16550A UART at `0x10000000`;
- `/init` started at kernel timestamp 91.546 seconds.

A subsequent causally paced runtime command returned:

```text
Linux (none) 7.2.0-rc4+ #6 PREEMPT Tue Jul 28 16:52:13 UTC 2026 riscv64 GNU/Linux
OPENRV64_RUNTIME_CMD_PASS
openrv64#
```

Implementation evidence for the exact bitstream:

- 71,828 of 71,828 routable nets fully routed;
- setup WNS +0.954 ns;
- hold WHS +0.047 ns;
- zero bitstream DRC errors;
- five post-route DRC warnings in generated MIG clock/DQS structures;
- 44,087 LUTs, 19,896 registers, and 68 BRAM tiles;
- zero unsafe CDC endpoints and 20 endpoints classified Unknown.

Focused validation also passed for a full 32-byte MIG line, a masked four-byte
tail, independent command/data backpressure, CRC32, calibration loss, and
gapless UART reception. These tests support the loader implementation; the
physical UART log is the boot evidence.

The CDC report is not clean signoff. Physical boot is functional evidence, not
a substitute for CDC review.

## Failure recovery

- If no `READY` marker appears, check UART direction, baud rate, FPGA
  programming, MIG calibration, and the live PTY/socat endpoint.
- Before `START`, an invalid header is discarded and the magic scanner can
  accept another header.
- After `START`, an interrupted or truncated payload cannot be restarted in
  place. Reprogram the FPGA to reset the loader, restore the UART bridge, and
  resend the complete image.
- After `CRC FAIL`, reprogram before retrying. Check the image hashes and the
  binary transparency of every bridge stage.
- Do not terminate the loader merely because the local PTY has accepted all
  bytes. Wait beyond the physical wire time for the hardware CRC result.

## Console limitation

The running 9.216 MHz system did not reliably consume arbitrary host bursts.
One unpaced 58-byte shell command caused:

```text
ttyS ttyS0: 1 input overrun(s)
```

and produced a garbled command. Character-at-a-time transmission with causal
echo pacing succeeded. Until the UART/driver path is improved, use human-rate
typing or an echo-paced console tool for interactive commands.

This limitation applies to Linux console input after boot. It is separate from
the pre-boot hardware loader, which received the complete binary stream and
verified it with CRC32.

## Evidence and scope

The complete run record is under:

```text
run/log/fpga-linux-uart-20260815T113302Z/
```

Key files:

- `result.md`: result summary and qualification
- `command.md`: protocol and final host command
- `uart-linux-hw-preload-final.log`: authoritative boot UART capture
- `uart-linux-runtime-command-paced.log`: successful runtime command
- `artifact-sha256.txt`: immutable artifact hashes
- `source-state-hw-preload.log`: dirty-worktree state
- `source-sha256-hw-preload.txt`: hashes of relevant source files
- `vivado-implement-hw-preload.log`: placement, routing, and bitgen log

The result proves one physical, single-hart boot through DDR3, OpenSBI,
Sv39/PTW, the 16550 driver, init, and an interactive shell. It does not prove:

- long-duration stability;
- storage or microSD boot;
- Ethernet operation;
- SMP operation;
- robust high-rate console RX;
- persistent SPI-flash configuration;
- CDC or product signoff.

The UART preload is deliberately a bring-up mechanism. A permanent boot flow
should load from storage or a faster debug/data transport rather than spend at
least seven minutes transmitting the kernel at 115200 baud.
