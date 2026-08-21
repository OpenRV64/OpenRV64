# MYD-J7A100T FPGA configuration smoke test

Status date: 2026-08-21 UTC

This document covers four separate bitstreams.  The cache-enabled SD-boot
image is the current physically booted artifact.  The inert pad-shell remains
the minimal JTAG and USB-UART-loopback baseline.  The older OpenSBI smoke image
adds the MYIR-derived MIG, a one-pipe OpenRV64 core, a ROM-to-DDR loader,
OpenSBI v1.9, and a small S-mode Sv39/PTW and timer payload.  The older Linux
image extends that design with a pre-boot hardware UART-to-MIG loader.  Do not
transfer claims between the four images.

An otherwise identical KEY_2-reset candidate was built and programmed on
2026-08-21, but has not yet had its UART boot or push-button behavior observed.
It is recorded separately below and does not replace the physically booted
artifact until that check passes.

## Current cache-enabled SD-boot artifact

The source-matched 2026-08-20 build is:

- Board: MYIR MYD-J7A100T / MYC-J7A100T-32Q512D-I
- FPGA: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Top: `openrv64_myd_j7a100t_opensbi_top`
- Bitstream:
  `build/fpga/xc7a100t/sd-boot-pmp8-cache32k-14mhz/openrv64_myd_j7a100t_sd_boot.bit`
- Size: 3,826,012 bytes
- SHA-256:
  `8d37fb1eea7cc11eca93d50016da96b99a8c5af0e684e90dc9d7a7be41db7d7b`
- Vivado: 2026.1 build 6511674
- Core and timebase clock: 14,000,000 Hz
- UART reference clock exposed to software: 14,745,600 Hz
- MIG UI and scalar-cache clock: 100,000,000 Hz
- UART: exact 115200 baud with divisor 8, 8 data bits, no parity, one stop bit

This image uses the one-pipe BP5 core profile, eight active PMP entries behind
the architecturally visible 16-entry PMP CSR surface, a four-entry generic
unified TLB, and no optional PTW non-leaf PTE cache.  The GPR uses the FPGA
LUTRAM implementation; the synthesis guards found 22 `RAM32M` cells.  RV64M
uses `rtl/core/exec/alu/rv64-m-fpga.v`; Vivado has 16 inferred `DSP48E1`
cells.  The core DCP includes the current MTL/PMP pipeline and was rebuilt from
the current RTL before the system and board netlists were linked, so this is
not a stale-core relink.

The core really runs at 14 MHz.  The 16550 remains in that clock domain but
uses a fractional reference prescaler: a 14.7456 MHz virtual reference makes
the standard integer divisor of eight produce exact 115200 baud.  This does
not add a UART clock domain.  The legacy UART regression passes, and a focused
14 MHz fractional test counted exactly 18,432 16x-baud ticks in 140,000 input
cycles with only seven- or eight-cycle tick intervals.

The scalar DDR path now has a 32 KiB direct-mapped read cache with 1,024
32-byte lines.  Reads allocate a complete 256-bit native-MIG beat.  Stores do
not allocate: every store remains blocking and write-through to DDR3, and it
invalidates the matching line.  Reset clears one tag per 100 MHz MIG UI cycle,
so the bridge remains unavailable for 1,024 cycles, about 10.24 microseconds.
The cache is not coherent with an independent post-boot MIG writer.  This SD
configuration disables the fixed and UART preloaders; the ROM loads DDR
through the cached scalar path, so its own stores invalidate lines correctly.
Adding another live MIG master would require explicit invalidation or bypass.
The image also includes the first 100-Mb/s RGMII Ethernet MAC candidate.  Its
two TX and two RX packet banks consume eight additional block-RAM tiles.  The
MAC, PHY management, and RGMII I/O have routed, but none has been validated on
the physical board yet.

Post-route physical results are:

- 34,429 slice LUTs (54.30%): 33,503 logic and 926 LUTRAM
- 16,056 slice registers (12.66%)
- 14,064 occupied slices (88.73%)
- 9,785 unique control sets (61.74%)
- 18 block-RAM tiles (13.33%): ten `RAMB36` plus sixteen `RAMB18`; the scalar
  cache accounts for eight tiles and Ethernet packet storage adds eight
- 16 DSPs (6.67%)
- full-design setup WNS +0.181 ns and hold WHS +0.010 ns; both are on the
  125 MHz RGMII receive domain
- 14 MHz core-domain setup WNS +2.138 ns and hold WHS +0.047 ns; its worst
  data path is 68.989 ns against a 71.429 ns period
- 60,038 of 60,038 routable nets fully routed, with zero routing errors
- zero DRC errors at bitstream generation

The remaining 131 DRC findings are 99 warnings and 32 advisories, mainly the
generated MIG DQS input-buffer warnings, unpipelined DSP ports, and
asynchronous BRAM control checks.  The CDC report is not signoff-clean: it
classifies 202 core-to-MIG-clock endpoints as unsafe and several other
endpoints as unknown.  Some of this is likely loss of synchronizer metadata
through the Yosys/import flow, but that has not been demonstrated.  Physical
boot is functional evidence, not CDC closure.

Build-time validation completed against this RTL:

- the ROM initialization guard found one initialized ROM and 66 nonzero INIT
  segments;
- the PMP CSR/enforcement test passed the 16-entry CSR surface, eight active
  entries, 4 KiB grain, WARL behavior, priorities, locks, and the serial
  address-update sequencer;
- the registered MTL PMP arbitration/tagged-response test passed;
- the focused scalar-MIG bridge test passed cache hits, same-line word hits,
  read fills, store write-through/invalidation, conflict eviction, masked
  stores, and out-of-range errors;
- the complete behavioral raw-card/DDR boot test printed the SD `START` and
  `PASS` markers and passed at 129,922 cycles.

On 2026-08-21 this bitstream was programmed into the physical `xc7a100t` over
the remote hardware server, and FPGA startup completed HIGH.  The UART capture
contained the FPGA and SD `PASS` markers, OpenSBI v1.9, `Boot HART PMP Count :
16`, Linux `/init`, `OPENRV64 BUSYBOX INIT`, and the literal `openrv64#`
prompt.  The earlier `error: insufficient PMP entries` and hart-isolation
failure did not recur.  OpenSBI counts the complete CSR surface; only entries
0 through 7 have storage and enforcement comparators, while entries 8 through
15 are WARL read-only zero.

The card used in that physical run still supplied the legacy DTB: OpenSBI
reported a 9,216,000 Hz timer and Linux reported a 9 MHz clocksource even
though the hardware core runs at 14 MHz.  Kernel time therefore ran about
1.52 times too fast.  This does not invalidate the PMP or boot-path result,
but it does invalidate timekeeping and performance measurements from that
run.  Rewrite the card with the source-matched image below before taking any
timing data:

```sh
python3 tools/make-fpga-sd-image.py \
  --timebase-frequency 14000000 \
  --uart-clock-frequency 14745600 \
  sw/opensbi.dts \
  build/opensbi-fpga-linux/artifacts/fw_jump.bin \
  sw/Image.Zicclsm \
  build/fpga/xc7a100t/sdcard/openrv64-myd-j7a100t-linux-sd-14mhz.bin
```

The generated 5,295,616-byte image was independently verified by the image
tool.  Its SHA-256 is
`05dd62a181c993ac8459e1ba2448758b2d2ff23baedfbe7117d640242f7aa126`.

Start UART capture first, then program volatile FPGA SRAM with:

```sh
/home/bill/bin/vivado -mode batch \
  -source synth/fpga/xc7a100t/program_bitstream.tcl \
  -tclargs TCP:<hw-server-host>:3121 \
  build/fpga/xc7a100t/sd-boot-pmp8-cache32k-14mhz/openrv64_myd_j7a100t_sd_boot.bit
```

With a valid raw SDHC/SDXC image in the socket, the required early sequence is:

```text
OPENRV64 FPGA BOOT PASS
OPENRV64 SD BOOT START
OPENRV64 SD BOOT PASS
OpenSBI v1.9
...
Linux version ...
...
openrv64#
```

The literal `openrv64#` prompt is the Linux-boot acceptance marker.  The FPGA
and SD `PASS` lines alone prove only MIG calibration and successful raw-image
validation, transfer, and jump.  The card format, image builder, destructive
whole-device `dd` command, and ROM failure markers are documented in
`doc/fpga/sd-boot-image.md`.

### KEY_2 reset candidate

The candidate bitstream is:

- Bitstream:
  `build/fpga/xc7a100t/sd-boot-pmp8-cache32k-14mhz-key2-reset/openrv64_myd_j7a100t_sd_boot.bit`
- SHA-256:
  `bbcadd73701f726026859ec42b58d9ac49ce5c1687553228357b41f038a9f4b1`
- Full-design setup WNS +0.513 ns and hold WHS +0.014 ns
- Fully routed with zero failed nets and zero bitstream-generation DRC errors

This build maps the top-level active-low `rst_n` input to `KEY_2` on package
pin P15 as LVCMOS33 with an internal pull-up.  The implemented I/O report
confirms P15, `rst_n`, LVCMOS33, and `PULLUP`.  Pressing the button is therefore
expected to assert reset if the board switch shorts P15 to ground; that board
switch polarity still requires physical observation.

Configuration startup remains independent of this user-I/O reset.  Xilinx
configuration initializes the 16-bit reset-hold register to zero; a later
falling edge on `rst_n` asynchronously clears the same register.  After either
event, MIG remains reset until the register saturates after 65,535 cycles of
the 200 MHz input clock.  P17 is `KEY_0` in the vendor constraints, not an
identified CPLD reset input, and is not claimed by this candidate.

Remote JTAG programming completed with startup HIGH.  That proves the released
P15 level did not hold FPGA startup in reset, but no UART bounce was available
to this build host.  Normal boot and reset-on-press/reset-on-release therefore
remain pending physical observation.

## Current Linux hardware-preload artifact

The physically booted Linux image is:

- Board: MYIR MYD-J7A100T / MYC-J7A100T-32Q512D-I
- FPGA: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Top: `openrv64_myd_j7a100t_opensbi_top`
- Bitstream:
  `build/fpga/xc7a100t/linux-hw-preload-tlb4/openrv64_myd_j7a100t_linux_hw_preload.bit`
- Size: 3,826,012 bytes
- SHA-256:
  `a957d2f1d1069dfb8a1e68f43101ecf8dd04942920e5b59fc709957e8b4930f8`
- Linux Image: `sw/Image.Zicclsm`, 5,021,332 bytes
- Linux Image SHA-256:
  `6d7071598d68d66199ea96834538cf95b51aaa45550d6dd871c0ba1c66a450ba`
- Linux Image CRC32: `8836c071`
- Vivado: 2026.1 build 6511674
- OpenSBI: v1.9, commit
  `cbf9f6734dd85a982c63e3cb5db7ffe09da839ca`
- Core, UART, and timebase clock: 9,216,000 Hz
- MIG UI and loader clock: 100,000,000 Hz
- UART: 115200 baud, 8 data bits, no parity, one stop bit

The fixed loader first writes a 32-byte trampoline to `0x80000000`, OpenSBI to
`0x80100000`, the existing small payload slot to `0x80200000`, and the DTB to
`0x8ff00000`.  The CPU remains in reset.  The hardware UART loader then accepts
a 16-byte header containing `ORV64LNX`, a little-endian 32-bit length, and an
IEEE CRC-32.  It streams the raw image into aligned 256-bit native-MIG writes
starting at `0x80200000`; the final partial line uses the MIG byte mask.  It
releases the CPU only after receiving the complete image, matching the CRC,
and finishing its PASS message.  The minimal trampoline then enters OpenSBI,
which enters Linux at `0x80200000` with the DTB at `0x8ff00000`.

Program volatile FPGA SRAM, ensure the UART bridge is active, then run:

```sh
/home/bill/.venv/bin/python tools/fpga-uart-linux-load.py \
  --device /tmp/ttyACM0 --ready-timeout 120 --boot-timeout 7200 \
  --hardware-preload sw/Image.Zicclsm
```

The required sequence is:

```text
OPENRV64 DDR LOAD READY
OPENRV64 DDR LOAD START
OPENRV64 DDR LOAD PASS
OPENRV64 FPGA BOOT PASS
OpenSBI v1.9
...
Linux version 7.2.0-rc4+
...
OPENRV64 BUSYBOX INIT
openrv64#
```

On 2026-08-15 this exact image was programmed into the physical `xc7a100t`.
FPGA startup completed HIGH, the hardware CRC passed, OpenSBI handed off in
S-mode, Linux reported 251,216 KiB available from 256 MiB, BusyBox init ran,
and the literal shell prompt was captured from the board UART.  A subsequent
causally paced `uname -a` returned Linux 7.2.0-rc4+ on `riscv64` and the shell
prompt returned.  The kernel reached `/init` at its timestamp 91.546 seconds.

The routed design has zero routing errors, setup WNS +0.954 ns, hold WHS
+0.047 ns, 44,087 LUTs, 19,896 registers, and 68 block-RAM tiles.  Bitstream
generation completed with zero DRC errors.  Focused simulation covers a full
32-byte line, a masked four-byte tail, independently stalled MIG command/data
channels, CRC32, and calibration loss.  The UART peripheral's gapless receive
regression also passes.

The five post-route DRC warnings are in generated MIG clock/DQS structures.
The CDC report has zero unsafe endpoints but 20 endpoints classified Unknown;
the physical boot is functional evidence, not CDC signoff.

The final provenance and UART capture are under
`run/log/fpga-linux-uart-20260815T113302Z/`; see `result.md` and
`uart-linux-hw-preload-final.log` there.

This result proves one single-hart physical boot through DDR3, OpenSBI,
Sv39/PTW, the 16550 driver, init, and a shell prompt.  It does not prove soak
stability, storage boot, Ethernet, SMP, or persistent configuration flash.
At 115200 baud the 5 MB preload has a minimum wire time of 435.9 seconds, so it
is a bring-up mechanism rather than a reasonable permanent boot path.
An unpaced 58-byte shell-command burst caused a `ttyS0` input overrun and
garbled input; character-at-a-time echo pacing worked.  Do not treat the
current console RX path as robust against host bursts.

## Current OpenSBI artifact

The physically validated OpenSBI image is:

- Board: MYIR MYD-J7A100T / MYC-J7A100T-32Q512D-I
- FPGA: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Top: `openrv64_myd_j7a100t_opensbi_top`
- Bitstream:
  `build/fpga/xc7a100t/opensbi-smoke-tlb4-split/openrv64_myd_j7a100t_opensbi_top.bit`
- Size: 3,826,012 bytes
- SHA-256:
  `cab65e11cff4b79f3eb2246dd5ac2cd4497d09ee2e9bdcfed5d773db8498760d`
- Vivado: 2026.1 build 6511674
- OpenSBI: v1.9, commit
  `cbf9f6734dd85a982c63e3cb5db7ffe09da839ca`
- Core, UART, and timebase clock: 9,216,000 Hz
- UART: 115200 baud, 8 data bits, no parity, one stop bit

The firmware loader writes the trampoline to `0x80000000`, OpenSBI to
`0x80100000`, the S-mode payload to `0x80200000`, and the DTB to `0x8ff00000`.
After programming, the required console sequence is:

```text
OPENRV64 FPGA BOOT WAIT
OPENRV64 FPGA BOOT PASS

OpenSBI v1.9
...
Domain0 Next Address        : 0x0000000080200000
Domain0 Next Arg1           : 0x000000008ff00000
Domain0 Next Mode           : S-mode
...
OPENRV64 SBI SV39 PTW PASS
```

On 2026-08-15 this exact image was loaded over JTAG into the detected
`xc7a100t`, FPGA startup completed HIGH, and all of the markers above were
captured from the physical board UART.  The routed image has zero failed nets,
setup WNS +0.574 ns, hold WHS +0.047 ns, 42,727 LUTs, 19,060 registers, and 68
block-RAM tiles.  The bitstream DRC has zero errors.  The remaining five DRC
warnings are inside the generated MIG clock and DQS structures.

This image proves DDR3 calibration/use, firmware population, execution from
DDR3, OpenSBI machine-mode initialization, timer interrupt delivery, and
S-mode handoff.  It also proves a physical three-level Sv39 walk from page
tables created in DDR3: root, level-1, and level-0 PTEs occupy line lanes 2, 1,
and 0; translated instruction/data execution reaches the distinct PTW PASS
marker.  The FPGA configuration has zero optional non-leaf PTE-cache entries.
The active one-pipe bus uses a four-entry generic unified TLB, reduced from its
normal 16-entry default for this area-constrained boot smoke test.  This is not
the ICX-path L2 TLB, which is not instantiated by this FPGA profile.  Four
entries are enough for this directed payload but are not performance evidence
for a Linux workload.  This reduction does not fix TLB SRAM inference: the
generic TLB still resets payload fields and performs an asynchronous parallel
read/compare across all entries.  A scalable replacement needs synchronous,
indexed per-way payload storage and an explicit extra lookup/replay cycle.

The PTW does not have a second AXI master.  A blocking core-clock-domain
arbiter shares the existing scalar CDC/MIG bridge.  Each 64-byte ICX page-table
line is fetched as eight serialized 64-bit reads and assembled before the ICX
response.  Ordinary scalar traffic has priority, and a PTW fence waits until
the shared path is idle.  This is deliberately low-complexity and slow; it is
functionally adequate for bring-up, not a performance target.

It is still not a Linux image.  The fixed boot ROM contains only the
trampoline, OpenSBI, the 448-byte PTW payload, and DTB.  A Linux boot needs a
separate way to place the kernel and any initramfs in DDR3, then a payload or
boot protocol that jumps to it.  The routed device is also physically dense:
15,398 of 15,850 slices are occupied even though paired LUT outputs reduce the
reported LUT use to 67.39%.  Treat further logic additions as requiring area
work, not as free use of the nominal remaining LUT count.

The CDC report has no unsafe crossings but still classifies four custom
core/MIG mailbox endpoints as Unknown; physical boot is functional evidence,
not CDC signoff.

The final build and physical validation record is under
`run/log/fpga-genbus-tlb4-split-20260815T110016Z/`.  Its source-matched parent
record is `run/log/fpga-genbus-tlb4-20260815T083202Z/` and includes directed
core/PTW regressions plus the exact integrated TLB4 OpenSBI/Sv39 simulation.
The split-flow record includes netlist provenance, Vivado logs/reports, the
programming log, and captured physical UART markers.  Vivado's ordinary
project flow was cancelled after spending 2:39:30 in top-level synthesis; the
split-netlist flow reached a bitstream in about 14 minutes.  Routing was not
the bottleneck.

Program it with the checked-in batch script while UART capture is already
active:

```sh
vivado -mode batch \
  -source synth/fpga/xc7a100t/program_bitstream.tcl \
  -tclargs <hw-server-host>:3121 \
  build/fpga/xc7a100t/opensbi-smoke-tlb4-split/openrv64_myd_j7a100t_opensbi_top.bit
```

This loads volatile FPGA SRAM only.  It does not write the configuration
flash.

## Baseline inert-shell artifact

The bitstream was generated with AMD Vivado 2026.1, build 6511674, for:

- Board: MYIR MYD-J7A100T / MYC-J7A100T-32Q512D-I
- FPGA: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Top: `openrv64_myd_j7a100t_top`
- Source constraint file: `synth/fpga/xc7a100t/myd_j7a100t.xdc`
- Bitstream: `build/fpga/xc7a100t/bitstream-shell/openrv64_myd_j7a100t_top.bit`
- Size: 304,530 bytes
- SHA-256:
  `13da04ef81f31c01c46eaca884518efc00c93af9aa69de985c79be2448d3f63a`

The `build/` directory is ignored by Git.  A repository clone therefore does
not contain the bitstream.  Transfer the `.bit` file separately and verify the
checksum before programming it.

On Linux:

```sh
sha256sum openrv64_myd_j7a100t_top.bit
```

On Windows PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\openrv64_myd_j7a100t_top.bit
```

Do not use an artifact with a different hash without recording its build
identity and expected behavior.

### Build evidence and limitations

The projectless implementation completed synthesis, placement, routing, DRC,
and bitstream generation.  The routed design has zero routing errors.  Bitgen
completed with zero errors.  The post-route DRC contains one warning because
the preserved 200 MHz input buffer deliberately has no internal load.

Resource use is effectively only I/O:

- 0 LUTs
- 0 registers
- 0 block RAMs
- 0 DSPs
- 51 implemented bonded I/O sites

The broader footprint check separately recognized all 112 top-level physical
ports and found no `NSTD-1`, `UCIO-1`, or `BIVC-1` violations.  The implemented
bitstream uses fewer I/O sites because Vivado removes unused inputs and
undriven bidirectional paths from this inert design.

The timing report says the constraints are met, but that is not useful CPU or
DDR timing evidence: there is no sequential core logic and no MIG in this
bitstream.

The bitstream was built from repository commit
`886f75ac96a9c6320e312864da5656a8ab3a9cd6` on branch `aj/zbb-blake2s`, plus an
uncommitted board-top correction that drives the static DDR3 clock pair through
an `OBUFDS`.  The source tree must contain that correction to reproduce the
artifact.

## What this bitstream does

After successful FPGA configuration:

- `uart_rx_i` is connected combinationally to `uart_tx_o`.  Bytes sent through
  the board USB-UART should return to the host.
- DDR3 remains inactive: reset is asserted, CKE is low, DQ/DQS are
  high-impedance, and the differential clock is held at a static level through
  an `OBUFDS`.
- Both Ethernet PHY reset outputs remain asserted.  RGMII transmit and MDC are
  inactive; MDIO is high-impedance.
- The microSD clock is low and CMD/DAT are high-impedance.
- The 200 MHz differential board clock is accepted by an `IBUFDS` but is not
  used.
- The active-low board reset input is not used.
- There is no CPU, ROM, UART peripheral, MIG, memory bridge, ILA, VIO, or debug
  hub.

Consequently, absence of console text is normal.  The only intended serial
behavior is immediate electrical loopback of characters transmitted by the
host.

## FPGA configuration properties

The checked-in constraints specify:

- `CFGBVS VCCO`
- configuration-bank voltage of 3.3 V
- `CONFIG_MODE SPIx4`
- SPI bus width of four bits
- configuration rate of 50 MHz
- compressed bitstream generation

For this smoke test, load the `.bit` file directly into FPGA configuration
SRAM through JTAG.  That operation is volatile.  A power cycle, assertion of
`PROGRAM_B`, or another configuration operation removes it; the board may then
load whatever image is already present in its SPI configuration flash.

**Do not select “Program Configuration Memory Device” and do not write the SPI
flash.**  No `.mcs` image has been generated, and the board's exact flash part
and persistent-boot procedure have not been verified.  The `SPIx4` properties
do not make this `.bit` file a reviewed persistent-flash image.

## Programming software

Use AMD Vivado Lab Edition 2026.1 on the computer physically connected to the
JTAG programmer.  It is the smallest straightforward installation for local
programming, includes Hardware Manager and `hw_server`, supports Vivado
devices, and does not require an activation license.  Full Vivado 2026.1 also
works.  Using the same release that generated the bitstream removes an
unnecessary version variable; exact version matching is not normally required
merely to load an Artix-7 `.bit` file.

Download **Vivado Lab Solutions 2026.1** from AMD's 2026.1 development-tools
page:

- <https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools/2026-1.html>

AMD currently lists the Lab Edition standalone archive as approximately
3.77 GB.  If using the unified/full installer instead, include Vivado and
7-Series/Artix-7 device support.  Vitis is not required.

The standalone Hardware Server is sufficient only when another machine already
has Vivado or Lab Edition and will act as the Hardware Manager client.  For a
single local programming computer, install Lab Edition instead.

### Windows installation

1. Run the Lab Edition installer as a normal installation workflow.
2. Enable the cable-driver installation option when offered.
3. If the driver was omitted, open an Administrator command prompt and run the
   driver wrapper from the installed release:

   ```bat
   cd <2026.1-install-root>\data\xicom\cable_drivers\nt64
   install_drivers_wrapper.bat <log-directory>
   ```

4. Unplug and reconnect the programmer after driver installation.
5. Confirm that Windows Device Manager reports the cable without an error.

### Linux installation

Install Lab Edition without root privileges.  Cable-driver installation is the
one step that AMD requires to run as root because it installs USB/udev support:

```sh
cd <2026.1-install-root>/data/xicom/cable_drivers/lin64/install_script/install_drivers
sudo ./install_drivers
```

Then unplug and reconnect the programmer so the new rules take effect.  Run
Vivado Lab Edition and `hw_server` as the normal user, not as root.

Load the installed environment before using command-line tools.  The exact
root is chosen during installation; typical commands are:

```sh
source <install-root>/Vivado_Lab/2026.1/settings64.sh
vivado_lab -version
hw_server -version
```

If the cable is visible to `lsusb` but Hardware Manager cannot open it, check
the driver-install log and udev permissions first.  Do not work around a
permissions problem by routinely running Vivado as root.

AMD's current `hw_server` support list includes Platform Cable USB II (DLC10),
Platform Cable USB variants DLC9/DLC9G/DLC9LP, SmartLynq, and several Digilent
JTAG cables.  Record the programmer's exact model and serial number in the test
report.  Do not reprogram an FTDI EEPROM or run `program_ftdi` merely because a
cable is not detected.

## Hardware connection

1. Record the board variant and the programmer model.  Confirm that the target
   FPGA marking/board documentation identifies an XC7A100T in FGG484.
2. Power the board off.
3. Connect the programmer to the board's JTAG header using the documented pin-1
   orientation.  The programmer's target-voltage reference must be connected;
   do not use the programmer to power the board unless the board and cable
   documentation explicitly require that.
4. Connect the board's USB-UART port to the programming computer.  This is
   separate from JTAG unless the board documentation explicitly combines them.
5. Connect the programmer's USB cable to the programming computer.
6. Power the board normally.

Do not guess the JTAG header orientation.  A reversed cable is a hardware
fault, not a software troubleshooting step.

## Program with Hardware Manager

1. Start Vivado Lab Edition 2026.1.
2. Open **Hardware Manager**.
3. Select **Open Target** and **Auto Connect**, or open a new target using the
   local hardware server.
4. Inspect the JTAG chain before programming.  It must contain an
   `xc7a100t`.  If Vivado reports another FPGA part, stop; do not force the
   image onto it.
5. Select the XC7A100T and choose **Program Device**.
6. Set the bitstream file to `openrv64_myd_j7a100t_top.bit`.
7. Leave the debug-probes file empty.  This design has no `.ltx` probes.
8. Program the FPGA and save the Hardware Manager log.

Successful `program_hw_devices` completion means that the JTAG transaction and
FPGA configuration/startup checks passed.  It does not establish that DDR3 or
the CPU works.

## Optional batch-mode programming

Hardware Manager Tcl can program the image without opening the GUI.  Save the
following as `program-openrv64-shell.tcl`:

```tcl
if {$argc != 1} {
    error "usage: vivado_lab -mode batch -source program-openrv64-shell.tcl -tclargs <bitstream>"
}

set bitfile [file normalize [lindex $argv 0]]
if {![file isfile $bitfile]} {
    error "bitstream not found: $bitfile"
}

open_hw_manager
connect_hw_server -url localhost:3121

set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {
    error "expected exactly one JTAG target, found [llength $targets]: $targets"
}
current_hw_target [lindex $targets 0]
open_hw_target

set devices [get_hw_devices -quiet xc7a100t*]
if {[llength $devices] != 1} {
    error "expected exactly one xc7a100t, found [llength $devices]: $devices"
}
set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device

puts "Programming [get_property PART $device] with $bitfile"
set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
puts "OPENRV64 PAD-SHELL PROGRAM PASS"

close_hw_target
disconnect_hw_server
close_hw_manager
```

With the cable connected and board powered, start the hardware server in one
terminal and leave it running:

```sh
hw_server
```

The default server URL is `localhost:3121`.  In a second terminal with the
same Vivado environment loaded, run:

```sh
vivado_lab -mode batch -nolog -nojournal \
  -source program-openrv64-shell.tcl \
  -tclargs ./openrv64_myd_j7a100t_top.bit
```

If more than one cable or more than one XC7A100T is connected, this script
stops rather than choosing a target implicitly.  Use Hardware Manager to
identify the intended chain in that case.

## UART loopback check

On Linux, identify the stable USB-UART path before and after connecting the
board:

```sh
ls -l /dev/serial/by-id/
```

Open it at 115200 baud, 8 data bits, no parity, and one stop bit.  For example:

```sh
picocom -b 115200 /dev/serial/by-id/<board-uart>
```

Disable local echo in the terminal.  Type a distinctive string such as:

```text
openrv64-shell-20260813
```

Each transmitted character should appear once because the FPGA returns the
serialized waveform immediately.  Baud rate is not generated inside the FPGA;
115200 8N1 is simply a convenient host setting for both directions.

If local echo is enabled, characters can appear even when the FPGA returns
nothing, or can appear twice when loopback works.  A visual test with local
echo enabled is invalid.

The UART result proves only:

- the FPGA retained the JTAG-loaded configuration;
- the constrained FPGA UART RX and TX pins correspond to the board USB-UART;
- the external USB-UART path can pass data in both directions.

It does not prove the 200 MHz oscillator, reset button, UART peripheral, CPU,
DDR3, OpenSBI, or Linux.

## Pass criteria and report

Call this smoke test a pass only when all of the following are recorded:

- Tool identifies itself as Vivado Lab Edition or Vivado 2026.1.
- Programmer model and serial number are recorded.
- Board variant/serial number are recorded if available.
- Bitstream SHA-256 exactly matches the value above.
- JTAG scan identifies `xc7a100t` before programming.
- Hardware Manager or batch Tcl reports successful programming.
- UART test is performed with terminal local echo disabled.
- The distinctive UART string is returned exactly once.
- Hardware Manager/programming and terminal logs are retained.

Recommended report fields:

```text
UTC date/time:
Operator:
Board model/revision/serial:
Programmer model/serial:
Host OS:
Vivado/Lab version:
Detected JTAG chain:
Bitstream filename:
Bitstream SHA-256:
Programming result:
USB-UART device:
UART settings:
UART transmitted string:
UART received string:
Unexpected observations:
Log locations:
```

## Failure triage

### No JTAG cable or target

- Confirm the board is powered and the programmer sees target reference
  voltage.
- Recheck header orientation and JTAG connector choice against board
  documentation.
- Confirm that the programmer appears in Device Manager or `lsusb`.
- Reinstall the AMD cable drivers, reconnect USB, and inspect permissions.
- Close other Vivado/Hardware Manager instances that may own the cable.
- Record the exact programmer model; unsupported clones are not equivalent to
  an AMD-supported cable merely because the connector fits.

### JTAG chain reports the wrong FPGA

Stop.  Recheck the board and chain.  Do not override the part mismatch or use
Vivado's force-programming options.

### Programming fails

- Re-verify the bitstream checksum.
- Save the exact `program_hw_devices` error.
- Check board power and programmer target voltage.
- Reduce JTAG frequency in Hardware Manager if signal integrity is suspect.
- Disconnect other JTAG clients and reopen the target.

Do not move to SPI-flash programming as a workaround.

### Programming passes but UART does not loop back

- Confirm Hardware Manager still shows the FPGA configured.
- Confirm the USB-UART device, not the JTAG programmer, was opened.
- Use 115200 8N1 and disable software/hardware flow control and local echo.
- Check the board USB-UART cable and driver.
- Verify that the tested artifact has the documented SHA-256.
- Record whether characters are absent, corrupted, or doubled.

No DDR, Ethernet, SD, console, or LED behavior should be inferred from this
failure.  Those blocks are deliberately inactive or absent.

## Optional remote cable host

If the programmer must remain attached to a remote bring-up computer, install
Lab Edition or the standalone Hardware Server there and run `hw_server` as a
normal user.  A Vivado/Lab client can then replace `localhost:3121` in the Tcl
script with `<bringup-host>:3121`.

Restrict TCP port 3121 to a trusted network or carry it through an authenticated
tunnel.  Prefer local programming for the first test so USB permissions,
target selection, and hardware observations remain on one machine.

## Next bitstream

Do not extend the conclusions from this shell.  The next functional image
requires, in order:

1. Board-generated 7-Series MIG and its generated constraints.
2. Reset release gated by `init_calib_complete`.
3. A core-to-MIG memory bridge and DDR read/write test.
4. A BRAM-resident UART loader.
5. OpenSBI/Linux image loading and console output.

That image will have different expected behavior, resource/timing evidence,
and a different checksum.  Create a separate artifact manifest rather than
editing the results of this smoke test after the fact.

## AMD references

- [Vivado 2026.1 downloads and Lab Solutions](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools/2026-1.html)
- [UG973: Download the Installation File](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Download-the-Installation-File)
- [UG973: Install Cable Drivers](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Install-Cable-Drivers)
- [UG908: Programming the Device](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Programming-the-Device)
- [UG908: JTAG Cables and Devices Supported by hw_server](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/JTAG-Cables-and-Devices-Supported-by-hw_server)
