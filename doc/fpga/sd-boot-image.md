# Raw microSD boot image

This is the raw-block format and boot path for the MYD-J7A100T FPGA design's
microSD socket. It is not a filesystem and has no partition table. Write the
image to the whole card, not to a partition.

The FPGA implementation uses the socket in SPI mode. It supports SD v2
block-addressed SDHC/SDXC cards, single-sector `CMD17` reads, and no writes.
SDSC byte addressing, native one/four-bit SD mode, filesystems, partitions,
multi-block reads, and error recovery are not implemented.

## Hardware and ROM flow

After MIG completes DDR3 calibration, the FPGA releases the core from reset.
The 4 KiB boot ROM then:

1. initializes the 115200 8N1 UART and SD card;
2. reads and validates the CRC-protected sector-zero header;
3. preserves its four 32-byte load descriptors in DDR stack scratch;
4. reads one 512-byte sector at a time into the SPI controller's inferred
   block RAM, copies exact payload bytes to DDR, and validates each CRC32;
5. executes `fence`, `fence.i`, and jumps to the trampoline at `0x80000000`.

The complete routed design uses two RAMB36 tiles: one for the 4 KiB ROM and one
for the 512-byte sector buffer. The SPI engine starts at approximately 384 kHz
and switches to 4.608 MHz after card initialization. The current ROM is
read-only and deliberately simple; a failed check prints a stage-specific
message and stops in `wfi`. The XDC reserves 50 ns of the 108.507 ns fast-mode
MISO cycle for card clock-to-out and PCB delay.

Build the ROM and run the behavioral card/DDR integration test with:

```sh
make fpga-sd-boot-rom sim-fpga-sd-boot
```

Build the physical bitstream with:

```sh
make fpga-sd-boot-bitstream
```

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
