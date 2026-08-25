# Raw microSD boot image

This is the raw-block format and boot path for the MYD-J7A100T FPGA design's
microSD socket. It is not a filesystem and has no partition table. Write the
image to the whole card, not to a partition.

The FPGA implementation uses the socket in SPI mode. It supports SD v2
block-addressed SDHC/SDXC cards, a single-sector `CMD17` header read,
multi-sector `CMD18` payload streams stopped by `CMD12`, and no writes. SDSC
byte addressing, native one/four-bit SD mode, filesystems, partitions, and
error recovery are not implemented.

## Hardware and ROM flow

After MIG completes DDR3 calibration, the FPGA releases the core from reset.
The 4 KiB boot ROM then:

1. initializes the 115200 8N1 UART and SD card;
2. reads and validates the CRC-protected sector-zero header;
3. preserves its four 32-byte load descriptors in DDR stack scratch;
4. opens one `CMD18` stream per load entry and programs its sector count into
   the SPI controller's autonomous receiver;
5. drains alternating 512-byte block-RAM banks to DDR while the controller
   fills the other bank, then stops the stream with `CMD12`;
6. copies aligned full words, handles the exact-length tail bytewise, and
   validates each payload with a table-driven CRC32;
7. executes `fence`, `fence.i`, and jumps to the trampoline at `0x80000000`.

Focused XC7 synthesis maps the two sector arrays to two separate `RAMB36E1`
primitives. This is standalone controller evidence, not a routed-system result;
a new full bitstream has not yet proved total device utilization or timing. The
current build rule selects a fast SPI half-period of
`ceil(core_clock / 20 MHz)` core cycles, which keeps SCK at or below 10 MHz.
That produces a 7 MHz SCK at a 14 MHz core, 10 MHz at 20 MHz, and 7.5 MHz at
30 MHz. The integer divider cannot generate exactly 10 MHz from every core
clock. At 10 MHz, a 7.45 MB image has an unavoidable approximately 6.0-second
data wire time before token, command, copy, or CRC overhead.

The receiver keeps SCK running through token search, 512 data bytes, and the
card's two CRC bytes. It pauses only when both banks are full, leaving CS
asserted, and resumes when software releases the next bank. A programmed block
count prevents it from clocking into an extra block before firmware sends
`CMD12`. The ROM is read-only; a failed check prints a stage-specific message
and stops in `wfi`. The XDC preserves at least a 50 ns launch-to-sample interval
and reserves 25 ns for card clock-to-out and PCB delay.

### Double-buffer MMIO

The SPI controller is based at `0x10030000`. Existing command transfers and
bank 0 remain compatible. The stream additions are:

| Offset | Access | Meaning |
| ---: | :---: | --- |
| `0x038` | W | Start autonomous receive; low 32 bits are the nonzero block count. CS must already be active. |
| `0x040` | R | Bit 0 active, bit 1 bank 0 ready, bit 2 bank 1 ready, bit 3 stream error, bit 4 current fill bank, bits 63:32 blocks not yet completed. |
| `0x048` | W | Release drained banks; write bit 0 for bank 0 and bit 1 for bank 1. |
| `0x100..0x2ff` | R | Synchronous 512-byte bank 0. |
| `0x300..0x4ff` | R | Synchronous 512-byte bank 1. |

Software must not release a bank until its copy and CRC update are complete.
Blocking transfers are rejected while the stream engine is active.

Build the ROM and run the behavioral card/DDR integration test through the
managed runner with:

```sh
run/run run/cfg/fpga-sd-boot-core-profile.cfg
```

The test uses multi-sector, non-eight-byte payload lengths. It checks exact DDR
contents and untouched padding, payload CRCs, and the expected command mix of
one header `CMD17` plus four `CMD18`/`CMD12` payload pairs. It also requires
bank 1 use, a both-banks-full backpressure event, and DDR writes overlapping an
active SPI receive.

The source-recorded 30 MHz-profile integration result is 314,810 cycles for
eight payload sectors. The immediately preceding single-buffer `CMD18`
baseline was 365,953 cycles, so the double buffer removes 51,143 cycles
(14.0%) in this focused model. A current CMD17-per-sector control is 357,130
cycles. These are behavioral integration measurements, not card or board
wall-clock measurements; the model has no real-card command latency.

The corresponding records are
`run/log/fpga-sd-boot-core-profile-20260825T190635Z/`,
`run/log/fpga-sd-boot-core-profile-20260825T183853Z/`, and
`run/log/fpga-sd-boot-single-block-control-20260825T190949Z/`. The focused
mapping record is
`run/log/fpga-spi-double-buffer-synth-20260825T190834Z/`.

Verify the two-bank XC7 mapping separately with:

```sh
run/run run/cfg/fpga-spi-double-buffer-synth.cfg
```

Build physical bitstreams through the corresponding managed FPGA experiment
configuration. Those configurations invoke the underlying
`fpga-sd-boot-bitstream` target and record the source state, bitstream, and
timing reports.

That split-netlist build reuses the existing core and MIG checkpoints under
`build/fpga/xc7a100t/opensbi-smoke/` and writes the result and reports under
`build/fpga/xc7a100t/sd-boot/`.

## Build

```sh
run/run fpga-sd-image --foreground
```

The managed command records the exact command, Git state, configuration, input
hashes, output hashes, and logs under `run/log/fpga-sd-image-<UTC>/`. It writes
the image and its JSON manifest under `build/fpga/xc7a100t/sdcard/`. The image
is deterministic when its three inputs and board parameters are unchanged.

The underlying tool has only three boot inputs. It preprocesses and compiles
the DTS and generates the fixed reset trampoline internally:

```sh
python3 tools/make-fpga-sd-image.py \
  sw/opensbi.dts \
  build/opensbi-fpga-linux/artifacts/fw_jump.bin \
  sw/Image.Zicclsm \
  build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd.bin
```

Verify an existing image independently:

```sh
python3 tools/make-fpga-sd-image.py --verify \
  build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd.bin
```

## Card layout

All integer fields are little-endian. LBA 0 contains one 512-byte header.
Payloads begin at LBA 8 and are packed consecutively into zero-padded sectors.

Header fields:

| Offset | Size | Value |
| ---: | ---: | --- |
| `0x00` | 8 | ASCII `ORV64SD1` |
| `0x08` | 4 | Format version, `1` |
| `0x0c` | 4 | Header bytes, `512` |
| `0x10` | 4 | Entry bytes, `32` |
| `0x14` | 4 | Entry count |
| `0x18` | 8 | Complete image length in bytes |
| `0x40` | 32 each | Load entries |
| `0x1fc` | 4 | IEEE CRC32 of bytes `0x000..0x1fb` |

Each load entry contains:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| `0x00` | 8 | Zero-padded ASCII tag |
| `0x08` | 4 | Starting LBA |
| `0x0c` | 4 | Allocated sector count |
| `0x10` | 8 | DDR load address |
| `0x18` | 4 | Exact payload byte length |
| `0x1c` | 4 | IEEE CRC32 of exact payload bytes |

The four required entries are `TRAMP` at `0x80000000`, `OPENSBI` at
`0x80100000`, `LINUX` at `0x80200000`, and `FDT` at `0x8ff00000`. After all
entries pass CRC validation, the ROM loader can enter the trampoline at
`0x80000000` with the hart ID in `a0`.

## Write to a card

First identify the whole-card device carefully. The following destroys its
existing partition table and data:

```sh
sudo dd if=build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd.bin \
  of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with the whole card device. Do not use a partition such as
`/dev/sdX1`.

## Program and observe

Start a 115200 8N1 UART capture before programming. Program volatile FPGA
SRAM with:

```sh
/home/bill/bin/vivado -mode batch \
  -source synth/fpga/xc7a100t/program_bitstream.tcl \
  -tclargs TCP:<hw-server-host>:3121 \
  build/fpga/xc7a100t/sd-boot/openrv64_myd_j7a100t_sd_boot.bit
```

The status UART holds the CPU in reset until MIG calibration completes and it
has transmitted:

```text
OPENRV64 FPGA BOOT PASS
```

The CPU boot ROM then owns the UART. A successful card load continues with:

```text
OPENRV64 SD BOOT START
OPENRV64 SD BOOT PASS
```

OpenSBI and Linux output should follow. The physical acceptance marker remains
the literal shell prompt `openrv64#`; the two FPGA/ROM `PASS` lines alone prove
only DDR calibration and image transfer/jump, not a Linux boot.

The ROM's failure lines are `NO CARD`, `INIT FAIL`, `HEADER FAIL`, `READ FAIL`,
and `CRC FAIL`. It does not retry or fall back to UART loading.
