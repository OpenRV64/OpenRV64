#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
vivado_bin=${VIVADO:-/home/bill/bin/vivado}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7k480t/core-3p-vivado}
part_name=${PART:-xc7k480tffg1156-2}
xdc_path=${XDC:-$repo_root/synth/fpga/xc7k480t/default.xdc}
rv64m_source=${RV64M_SOURCE:-rtl/core/exec/alu/rv64-m-fpga.v}

retire_depth=${RETIRE_DEPTH:-32}
issue_window_depth=${ISSUE_WINDOW_DEPTH:-$retire_depth}
phys_reg_count=${PHYS_REG_COUNT:-31}
rename_mode=${RENAME_MODE:-0}
banked_gpr=${BANKED_GPR:-0}
fpga_gpr_lutram=${FPGA_GPR_LUTRAM:-0}
issue_window=${ISSUE_WINDOW:-1}
speculation_window=${SPECULATION_WINDOW:-1}
branch_completion_forward_mask=${BRANCH_COMPLETION_FORWARD_MASK:-1}
relax_waw=${RELAX_WAW:-1}
enable_l1i=${ENABLE_L1I:-1}
enable_l1d=${ENABLE_L1D:-1}
no_timing_driven=${NO_TIMING_DRIVEN:-0}
l1d_retired_store_mshr_canonical=${L1D_RETIRED_STORE_MSHR_CANONICAL:-0}

if ! vivado_bin=$(command -v "$vivado_bin"); then
    echo "error: Vivado executable not found: ${VIVADO:-/home/bill/bin/vivado}" >&2
    exit 2
fi
if [[ ! -s "$repo_root/$rv64m_source" ]]; then
    echo "error: FPGA RV64M source not found: $rv64m_source" >&2
    exit 2
fi
if [[ ! -s "$xdc_path" ]]; then
    echo "error: XC7K480T constraint file not found: $xdc_path" >&2
    exit 2
fi

mkdir -p "$output_dir"

mapfile -t rtl_sources < <(
    cd "$repo_root"
    make RV64M_EXEC_SRC="$rv64m_source" -pn 2>/dev/null |
        awk '/^CORE_3P_AXI_SRCS :=/ {
            for (i = 3; i <= NF; i++)
                if (!seen[$i]++ && $i !~ /\/debug\/stub[.]v$/)
                    print $i
        }'
)

if (( ${#rtl_sources[@]} == 0 )); then
    echo "error: could not extract CORE_3P_AXI_SRCS from make" >&2
    exit 2
fi

source_list=$output_dir/rtl-sources.txt
printf '%s\n' "$repo_root/rtl/openrv64_top_3p.v" > "$source_list"
for source in "${rtl_sources[@]}"; do
    printf '%s\n' "$repo_root/$source" >> "$source_list"
done

export OPENRV64_SYNTH_RETIRE_DEPTH=$retire_depth
export OPENRV64_SYNTH_ISSUE_WINDOW_DEPTH=$issue_window_depth
export OPENRV64_SYNTH_PHYS_REG_COUNT=$phys_reg_count
export OPENRV64_SYNTH_RENAME_MODE=$rename_mode
export OPENRV64_SYNTH_BANKED_GPR=$banked_gpr
export OPENRV64_SYNTH_FPGA_GPR_LUTRAM=$fpga_gpr_lutram
export OPENRV64_SYNTH_ISSUE_WINDOW=$issue_window
export OPENRV64_SYNTH_SPECULATION_WINDOW=$speculation_window
export OPENRV64_SYNTH_BRANCH_COMPLETION_FORWARD_MASK=$branch_completion_forward_mask
export OPENRV64_SYNTH_RELAX_WAW=$relax_waw
export OPENRV64_SYNTH_ENABLE_L1I=$enable_l1i
export OPENRV64_SYNTH_ENABLE_L1D=$enable_l1d
export OPENRV64_SYNTH_NO_TIMING_DRIVEN=$no_timing_driven
export OPENRV64_SYNTH_L1D_RETIRED_STORE_MSHR_CANONICAL=$l1d_retired_store_mshr_canonical

printf 'OPENRV64 XC7K480T 3P VIVADO CONFIG retire=%s scheduler=%s phys=%s rename=%s banked_gpr=%s gpr_lutram=%s l1i=%s l1d=%s no_timing_driven=%s\n' \
    "$retire_depth" "$issue_window_depth" "$phys_reg_count" \
    "$rename_mode" "$banked_gpr" "$fpga_gpr_lutram" \
    "$enable_l1i" "$enable_l1d" "$no_timing_driven"

"$vivado_bin" -mode batch -nojournal \
    -log "$output_dir/vivado.log" \
    -source "$script_dir/synth_vivado_3p_core.tcl" \
    -tclargs "$source_list" "$xdc_path" "$output_dir" \
    "$part_name" "$repo_root"

test -s "$output_dir/openrv64_core_3p.dcp"
test -s "$output_dir/utilization.rpt"
test -s "$output_dir/utilization_hierarchical.rpt"
test -s "$output_dir/timing_synth.rpt"

printf 'OPENRV64 XC7K480T 3P VIVADO PASS dcp=%s utilization=%s\n' \
    "$output_dir/openrv64_core_3p.dcp" "$output_dir/utilization.rpt"
