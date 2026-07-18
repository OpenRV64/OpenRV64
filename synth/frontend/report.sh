#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

yosys_bin=${YOSYS:-yosys}
out_dir_arg=${OUT_DIR:-sim/yosys/frontend}
liberty=${LIBERTY:-}
abc_constr=${ABC_CONSTR:-}
abc_delay_ps=${ABC_DELAY_PS:-}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi

if [[ "$out_dir_arg" == /* ]]; then
    out_dir=$out_dir_arg
    out_dir_display=$out_dir_arg
else
    out_dir="$repo_root/$out_dir_arg"
    out_dir_display=$out_dir_arg
fi

if [[ -n "$liberty" && "$liberty" != /* ]]; then
    liberty="$repo_root/$liberty"
fi

if [[ -n "$abc_constr" && "$abc_constr" != /* ]]; then
    abc_constr="$repo_root/$abc_constr"
fi

if [[ -n "$liberty" && ! -f "$liberty" ]]; then
    echo "error: Liberty file does not exist: $liberty" >&2
    exit 2
fi

if [[ -n "$abc_constr" && ! -f "$abc_constr" ]]; then
    echo "error: ABC constraint file does not exist: $abc_constr" >&2
    exit 2
fi

if [[ -n "$abc_constr" && -z "$liberty" ]]; then
    echo "error: ABC_CONSTR requires LIBERTY" >&2
    exit 2
fi

if [[ -n "$abc_delay_ps" && ! "$abc_delay_ps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "error: ABC_DELAY_PS must be a non-negative number" >&2
    exit 2
fi

mkdir -p "$out_dir"
cd "$out_dir"

reports=(
    "replay-lookup:openrv64_timing_fetch_replay_lookup"
    "full-replay:openrv64_timing_frontend_replay"
    "predecode-offset:openrv64_timing_fetch_predecode_offset"
)

verilog_sources="\"$repo_root/rtl/core/exec/bp/always_branch.v\" \"$repo_root/synth/frontend/replay-timing.v\""

for report_spec in "${reports[@]}"; do
    report_name=${report_spec%%:*}
    top_module=${report_spec#*:}
    report_path="$report_name.rpt"
    report_display="$out_dir_display/$report_name.rpt"
    abc_options=""

    if [[ -n "$abc_constr" ]]; then
        abc_options="$abc_options -constr \"$abc_constr\""
    fi
    if [[ -n "$abc_delay_ps" ]]; then
        abc_options="$abc_options -D $abc_delay_ps"
    fi

    if [[ -n "$liberty" ]]; then
        flow="read_verilog -sv -I$repo_root/rtl $verilog_sources; hierarchy -check -top $top_module; proc; flatten; opt; memory; opt; techmap; opt; dfflibmap -liberty \"$liberty\"; abc -liberty \"$liberty\"$abc_options; clean -purge; stat -liberty \"$liberty\"; read_liberty -lib \"$liberty\"; check;"
        "$yosys_bin" -Q -l "$report_path" -p "$flow" >/dev/null

        delay_ps=$(sed -n 's/.*Delay = *\([0-9.][0-9.]*\) ps.*/\1/p' "$report_path" | tail -1)
        area=$(sed -n "s/.*Chip area for module.*: *\([0-9.][0-9.]*\).*/\1/p" "$report_path" | tail -1)
        start_end=$(sed -n 's/^ABC: Start-point = /start=/p' "$report_path" | tail -1)
        if [[ -n "$delay_ps" ]]; then
            fmax_mhz=$(awk -v delay_ps="$delay_ps" 'BEGIN { printf "%.1f", 1000000.0 / delay_ps }')
            printf '%-20s %8.2f ps  %7s MHz  area=%s\n' \
                "$report_name" "$delay_ps" "$fmax_mhz" "${area:-unknown}"
            printf '  %s\n  report: %s\n' "$start_end" "$report_display"
        else
            printf '%-20s technology mapped, no combinational path reported\n' \
                "$report_name"
            printf '  report: %s\n' "$report_display"
        fi
    else
        flow="read_verilog -sv -I$repo_root/rtl $verilog_sources; hierarchy -check -top $top_module; proc; flatten; opt; memory; opt; techmap; opt; abc -g simple; clean -purge; tee -o \"$report_path\" stat; tee -a \"$report_path\" ltp -noff;"
        "$yosys_bin" -Q -q -p "$flow"
        depth=$(sed -n 's/.*Longest topological path.*length=\([0-9][0-9]*\).*/\1/p' "$report_path" | tail -1)
        printf '%-20s generic depth: %s gates (%s)\n' \
            "$report_name" "${depth:-unknown}" "$report_display"
    fi
done
