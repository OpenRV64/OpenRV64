# Raw microSD boot image

This is the provisional raw-block format for booting the MYD-J7A100T FPGA
design from its microSD socket. It is not a filesystem and has no partition
table. Write the image to the whole card, not to a partition.

The current FPGA bitstream does **not** read this format yet. The SPI-mode SD
controller, ROM loader, and MIG write path still have to be integrated. This
format fixes the loader-facing sector ABI and packages the artifacts from the
physically validated UART-preload Linux boot.

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
