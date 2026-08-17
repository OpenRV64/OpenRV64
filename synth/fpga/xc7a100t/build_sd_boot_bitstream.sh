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
                "$mig_stub" "$mig_dcp" "$mig_xdc" "$board_xdc"; do
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
make FPGA_SD_BOOT_DIR="$output_dir" fpga-sd-boot-rom

env OUT_DIR="$output_dir" CORE_STUB="$core_stub" \
    LOADER_STUB="$loader_stub" ROM_INIT_FILE="$rom_mem" \
    SD_ROM_BOOT_ENABLE=1 UART_LINUX_LOAD_ENABLE=0 \
    OUTPUT_EDIF="$system_edif" OUTPUT_JSON="$system_json" \
    OUTPUT_STUB="$system_stub" OUTPUT_LOG="$output_dir/yosys-system.log" \
    "$script_dir/build_yosys_opensbi_system.sh"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/link_vivado_opensbi_system.tcl" \
    -tclargs "$system_edif" "$core_dcp" "$system_dcp"

env OUT_DIR="$output_dir" SYSTEM_STUB="$system_stub" MIG_STUB="$mig_stub" \
    OUTPUT_EDIF="$top_edif" OUTPUT_JSON="$top_json" \
    OUTPUT_LOG="$output_dir/yosys-board.log" \
    "$script_dir/build_yosys_opensbi_board.sh"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/link_vivado_opensbi_top.tcl" \
    -tclargs "$top_edif" "$system_dcp" "$mig_dcp" "$linked_dcp"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/opt_vivado_opensbi_top.tcl" \
    -tclargs "$linked_dcp" "$mig_xdc" "$board_xdc" \
    "$optimized_dcp" "$report_dir"

"$vivado_bin" -mode batch -nojournal -nolog \
    -source "$script_dir/implement_vivado_opensbi_top.tcl" \
    -tclargs "$optimized_dcp" "$output_bit" "$report_dir"

sha256sum "$output_bit"
printf 'OPENRV64 FPGA SD BOOT BITSTREAM PASS: %s\n' "$output_bit"
