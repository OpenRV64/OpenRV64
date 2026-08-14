# MYD-J7A100T FPGA configuration smoke test

Status date: 2026-08-13 UTC

This procedure programs the current OpenRV64 **inert pad-shell** into the FPGA
over JTAG and checks its USB-UART loopback.  It validates the programming path,
the selected FPGA part, and two UART pins.  It does not run an OpenRV64 core or
exercise DDR3, microSD, or Ethernet.

## Current artifact

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
