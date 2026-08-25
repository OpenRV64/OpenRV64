#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
vivado_bin=${VIVADO:-/home/bill/bin/vivado}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7a100t/sd-boot}
base_dir=${BASE_FPGA_DIR:-$repo_root/build/fpga/xc7a100t/opensbi-smoke}
rom_mem=${ROM_INIT_FILE:-$output_dir/fpga-sd-boot.mem}
core_stub=${CORE_STUB:-$base_dir/openrv64_fpga_core_stub.v}
core_dcp=${CORE_DCP:-$base_dir/openrv64_fpga_core.dcp}
loader_stub=${LOADER_STUB:-$base_dir/openrv64_fpga_loader_fixed_stub.v}
mig_dir=${MIG_DIR:-$base_dir/project/generated-ip/mig_7series_0}
mig_stub=${MIG_STUB:-$mig_dir/mig_7series_0_stub.v}
mig_dcp=${MIG_DCP:-$mig_dir/mig_7series_0.dcp}
mig_xdc=${MIG_XDC:-$mig_dir/mig_7series_0/user_design/constraints/mig_7series_0.xdc}
board_xdc=${BOARD_XDC:-$script_dir/opensbi_smoke.xdc}
jtag_xdc=${JTAG_XDC:-$script_dir/jtag_snoop.xdc}
rom_uart_divisor=${FPGA_SD_BOOT_UART_DIVISOR:-8}
core_clock_hz=${FPGA_CORE_CLOCK_HZ:-14000000}
core_clock_multiply=${FPGA_CORE_CLOCK_MULTIPLY:-7}
core_clock_divide=${FPGA_CORE_CLOCK_DIVIDE:-50}
uart_reference_clock_hz=${FPGA_UART_REFERENCE_CLOCK_HZ:-14745600}
spi_fast_half_period_cycles=${FPGA_SPI_FAST_HALF_PERIOD_CYCLES:-}
ethernet_mdc_half_period_cycles=${FPGA_ETHERNET_MDC_HALF_PERIOD_CYCLES:-}
ethernet_phy_reset_cycles=${FPGA_ETHERNET_PHY_RESET_CYCLES:-}
mig_scalar_cache_enable=${FPGA_MIG_SCALAR_CACHE_ENABLE:-1}
mig_scalar_cache_bytes=${FPGA_MIG_SCALAR_CACHE_BYTES:-32768}

for value_name in core_clock_hz core_clock_multiply core_clock_divide \
                  uart_reference_clock_hz; do
    value=${!value_name}
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: $value_name must be a positive integer" >&2
        exit 2
    fi
done
if (( 100000000 * core_clock_multiply !=
      core_clock_hz * core_clock_divide )); then
    echo "error: FPGA core clock parameters do not produce $core_clock_hz Hz" >&2
    exit 2
fi
# MMCME2_BASE uses DIVCLK_DIVIDE=1 and is driven by the 100 MHz MIG UI
# clock.  Keep its VCO in the 7-series 600-1200 MHz operating range and
# reject parameter values that Vivado would otherwise drop from the EDIF.
if (( core_clock_multiply < 6 || core_clock_multiply > 12 )); then
    echo "error: FPGA_CORE_CLOCK_MULTIPLY must be 6..12 for the 100 MHz MMCM input" >&2
    exit 2
fi
if (( core_clock_divide < 1 || core_clock_divide > 128 )); then
    echo "error: FPGA_CORE_CLOCK_DIVIDE must be 1..128" >&2
    exit 2
fi
# Keep fast-mode SCK at or below 10 MHz.  The divider is expressed in whole
# core-clock half-periods, so some core clocks produce a lower exact rate.
minimum_spi_half_period_cycles=$(((core_clock_hz + 19999999) / 20000000))
if [[ -z "$spi_fast_half_period_cycles" ]]; then
    spi_fast_half_period_cycles=$minimum_spi_half_period_cycles
elif [[ ! "$spi_fast_half_period_cycles" =~ ^[1-9][0-9]*$ ]] ||
     (( spi_fast_half_period_cycles < minimum_spi_half_period_cycles )); then
    echo "error: FPGA_SPI_FAST_HALF_PERIOD_CYCLES must be an integer >= $minimum_spi_half_period_cycles" >&2
    exit 2
fi
if [[ -z "$ethernet_mdc_half_period_cycles" ]]; then
    ethernet_mdc_half_period_cycles=$(((core_clock_hz + 4999999) / 5000000))
fi
if [[ -z "$ethernet_phy_reset_cycles" ]]; then
    # Preserve the existing 110,000-cycle reset interval at 14 MHz.
    ethernet_phy_reset_cycles=$(((core_clock_hz * 110000 + 13999999) / 14000000))
fi

if [[ ${FPGA_SD_BOOT_PRINT_CLOCK_CONFIG:-0} == 1 ]]; then
    spi_fast_clock_hz=$((core_clock_hz / (2 * spi_fast_half_period_cycles)))
    printf 'core_clock_hz=%s spi_fast_half_period_cycles=%s spi_fast_clock_hz=%s\n' \
        "$core_clock_hz" "$spi_fast_half_period_cycles" \
        "$spi_fast_clock_hz"
    exit 0
fi

system_edif=$output_dir/openrv64_fpga_opensbi_system.edif
system_json=$output_dir/openrv64_fpga_opensbi_system.json
system_stub=$output_dir/openrv64_fpga_opensbi_system_stub.v
system_dcp=$output_dir/openrv64_fpga_opensbi_system.dcp
top_edif=$output_dir/openrv64_myd_j7a100t_opensbi_top.edif
top_json=$output_dir/openrv64_myd_j7a100t_opensbi_top.json
linked_dcp=$output_dir/openrv64_sd_boot_linked_top.dcp
optimized_dcp=$output_dir/openrv64_sd_boot_post_opt.dcp
output_bit=$output_dir/openrv64_myd_j7a100t_sd_boot.bit
report_dir=$output_dir/reports

for artifact in "$core_stub" "$core_dcp" "$loader_stub" \
                "$mig_stub" "$mig_dcp" "$mig_xdc" "$board_xdc" \
                "$jtag_xdc"; do
    if [[ ! -s "$artifact" ]]; then
        echo "error: required FPGA artifact not found: $artifact" >&2
        exit 2
    fi
done
if [[ ! -x "$vivado_bin" ]]; then
    echo "error: Vivado launcher is not executable: $vivado_bin" >&2
    exit 2
fi

mkdir -p "$output_dir" "$report_dir"
cd "$repo_root"
make FPGA_SD_BOOT_DIR="$output_dir" \
    FPGA_SD_BOOT_UART_DIVISOR="$rom_uart_divisor" fpga-sd-boot-rom

env OUT_DIR="$output_dir" CORE_STUB="$core_stub" \
    LOADER_STUB="$loader_stub" ROM_INIT_FILE="$rom_mem" \
    FPGA_CORE_CLOCK_HZ="$core_clock_hz" \
    FPGA_UART_REFERENCE_CLOCK_HZ="$uart_reference_clock_hz" \
    FPGA_SPI_FAST_HALF_PERIOD_CYCLES="$spi_fast_half_period_cycles" \
    FPGA_ETHERNET_MDC_HALF_PERIOD_CYCLES="$ethernet_mdc_half_period_cycles" \
    FPGA_ETHERNET_PHY_RESET_CYCLES="$ethernet_phy_reset_cycles" \
    FPGA_MIG_SCALAR_CACHE_ENABLE="$mig_scalar_cache_enable" \
    FPGA_MIG_SCALAR_CACHE_BYTES="$mig_scalar_cache_bytes" \
    SD_ROM_BOOT_ENABLE=1 UART_LINUX_LOAD_ENABLE=0 \
    OUTPUT_EDIF="$system_edif" OUTPUT_JSON="$system_json" \
    OUTPUT_STUB="$system_stub" OUTPUT_LOG="$output_dir/yosys-system.log" \
    "$script_dir/build_yosys_opensbi_system.sh"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/link_vivado_opensbi_system.tcl" \
    -tclargs "$system_edif" "$core_dcp" "$system_dcp"

env OUT_DIR="$output_dir" SYSTEM_STUB="$system_stub" MIG_STUB="$mig_stub" \
    FPGA_CORE_CLOCK_MULTIPLY="$core_clock_multiply" \
    FPGA_CORE_CLOCK_DIVIDE="$core_clock_divide" \
    OUTPUT_EDIF="$top_edif" OUTPUT_JSON="$top_json" \
    OUTPUT_LOG="$output_dir/yosys-board.log" \
    "$script_dir/build_yosys_opensbi_board.sh"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/link_vivado_opensbi_top.tcl" \
    -tclargs "$top_edif" "$system_dcp" "$mig_dcp" "$linked_dcp"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/opt_vivado_opensbi_top.tcl" \
    -tclargs "$linked_dcp" "$mig_xdc" "$board_xdc" "$jtag_xdc" \
    "$optimized_dcp" "$report_dir"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/implement_vivado_opensbi_top.tcl" \
    -tclargs "$optimized_dcp" "$output_bit" "$report_dir"

sha256sum "$output_bit"
printf 'OPENRV64 FPGA SD BOOT BITSTREAM PASS: %s\n' "$output_bit"
