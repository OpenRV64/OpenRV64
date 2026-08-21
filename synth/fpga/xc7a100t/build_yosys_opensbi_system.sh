#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
yosys_bin=${YOSYS:-yosys}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7a100t/opensbi-smoke}
core_stub=${CORE_STUB:-$output_dir/openrv64_fpga_core_stub.v}
loader_stub=${LOADER_STUB:-$output_dir/openrv64_fpga_loader_fixed_stub.v}
output_edif=${OUTPUT_EDIF:-$output_dir/openrv64_fpga_opensbi_system.edif}
output_json=${OUTPUT_JSON:-$output_dir/openrv64_fpga_opensbi_system.json}
output_stub=${OUTPUT_STUB:-$output_dir/openrv64_fpga_opensbi_system_stub.v}
output_log=${OUTPUT_LOG:-$output_dir/yosys-system.log}
uart_linux_load_enable=${UART_LINUX_LOAD_ENABLE:-0}
sd_rom_boot_enable=${SD_ROM_BOOT_ENABLE:-0}
rom_init_file=${ROM_INIT_FILE:-}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi
for stub in "$core_stub" "$loader_stub"; do
    if [[ ! -s "$stub" ]]; then
        echo "error: required partition stub not found: $stub" >&2
        exit 2
    fi
done
if [[ "$uart_linux_load_enable" != 0 &&
      "$uart_linux_load_enable" != 1 ]]; then
    echo "error: UART_LINUX_LOAD_ENABLE must be 0 or 1" >&2
    exit 2
fi
if [[ "$sd_rom_boot_enable" != 0 && "$sd_rom_boot_enable" != 1 ]]; then
    echo "error: SD_ROM_BOOT_ENABLE must be 0 or 1" >&2
    exit 2
fi
if [[ "$sd_rom_boot_enable" == 1 && ! -s "$rom_init_file" ]]; then
    echo "error: SD boot ROM init file not found: $rom_init_file" >&2
    exit 2
fi

mkdir -p "$output_dir"

sources=(
    "$core_stub"
    "$loader_stub"
    "$repo_root/rtl/soc/platform.sv"
    "$repo_root/rtl/soc/reset_sequencer.v"
    "$repo_root/rtl/soc/bus/decode.v"
    "$repo_root/rtl/soc/bus/rom.v"
    "$repo_root/rtl/soc/bus/memory.v"
    "$repo_root/rtl/clint/clint.v"
    "$repo_root/rtl/plic/plic.v"
    "$repo_root/rtl/periph/uart/uart.v"
    "$repo_root/rtl/periph/gpio/gpio.v"
    "$repo_root/rtl/periph/timer/timer.v"
    "$repo_root/rtl/periph/spi/spi.v"
    "$repo_root/rtl/periph/ethernet/packet_ram.sv"
    "$repo_root/rtl/periph/ethernet/emaclite.sv"
    "$script_dir/uart_banner.sv"
    "$script_dir/uart_ddr_loader.sv"
    "$script_dir/mig_scalar_bridge.sv"
    "$script_dir/scalar_mem_cdc.sv"
    "$script_dir/scalar_icx_arbiter.sv"
    "$script_dir/opensbi_boot_uart_status.sv"
    "$script_dir/opensbi_system.sv"
)

read_command="read_verilog -sv -defer -I$repo_root/rtl \
    -DSYNTHESIS -DOPENRV64_FPGA_CORE_NETLIST \
    -DOPENRV64_FPGA_LOADER_NETLIST \
    -DOPENRV64_XILINX_PACKET_RAM"
if [[ -n "$rom_init_file" ]]; then
    # The ROM wraps this bare path in SystemVerilog macro quotes. A
    # string-valued chparam reaches the module parameter but is not honored by
    # Yosys $readmemh.
    read_command+=" -DOPENRV64_SYNTH_ROM_INIT_FILE=$rom_init_file"
fi
for source in "${sources[@]}"; do
    read_command+=" \"$source\""
done

flow="read_verilog -lib +/xilinx/cells_sim.v; \
$read_command; \
chparam -set UART_LINUX_LOAD_ENABLE $uart_linux_load_enable \
        -set SD_ROM_BOOT_ENABLE $sd_rom_boot_enable \
        -set ROM_INIT_FILE \"$rom_init_file\" \
        openrv64_fpga_opensbi_system; \
hierarchy -check -top openrv64_fpga_opensbi_system; \
synth_xilinx -family xc7 -top openrv64_fpga_opensbi_system -flatten \
    -noiopad -noclkbuf; \
delete t:\$scopeinfo; \
hierarchy -check -top openrv64_fpga_opensbi_system; \
check -noinit; \
write_edif -pvector bra \"$output_edif\"; \
write_json \"$output_json\"; \
blackbox openrv64_fpga_opensbi_system; \
setattr -mod -set black_box 1 =openrv64_fpga_opensbi_system; \
select =openrv64_fpga_opensbi_system; \
write_verilog -blackboxes -selected \"$output_stub\""

cd "$repo_root"
"$yosys_bin" -q -l "$output_log" -p "$flow"

test -s "$output_edif"
test -s "$output_json"
test -s "$output_stub"
if [[ "$sd_rom_boot_enable" == 1 ]]; then
    python3 "$repo_root/tools/check_yosys_rom_init.py" "$output_json"
fi
printf 'OpenRV64 FPGA system EDIF: %s\n' "$output_edif"
