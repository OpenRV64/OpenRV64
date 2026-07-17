#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

report_set=${1:-all}
yosys_bin=${YOSYS:-yosys}
out_dir_arg=${OUT_DIR:-sim/yosys/alu}
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

case "$report_set" in
    all|rv64i|rv64m) ;;
    *)
        echo "usage: $0 [all|rv64i|rv64m]" >&2
        exit 2
        ;;
esac

mkdir -p "$out_dir"
cd "$out_dir"

rv64i_reports=(
    "rv64i-full:openrv64_exec_alu_rv64i"
    "rv64i-add:openrv64_timing_alu_rv64i_add"
    "rv64i-addw:openrv64_timing_alu_rv64i_addw"
    "rv64i-sub:openrv64_timing_alu_rv64i_sub"
    "rv64i-subw:openrv64_timing_alu_rv64i_subw"
    "rv64i-sll:openrv64_timing_alu_rv64i_sll"
    "rv64i-sllw:openrv64_timing_alu_rv64i_sllw"
    "rv64i-slt:openrv64_timing_alu_rv64i_slt"
    "rv64i-sltu:openrv64_timing_alu_rv64i_sltu"
    "rv64i-xor:openrv64_timing_alu_rv64i_xor"
    "rv64i-srl:openrv64_timing_alu_rv64i_srl"
    "rv64i-srlw:openrv64_timing_alu_rv64i_srlw"
    "rv64i-sra:openrv64_timing_alu_rv64i_sra"
    "rv64i-sraw:openrv64_timing_alu_rv64i_sraw"
    "rv64i-or:openrv64_timing_alu_rv64i_or"
    "rv64i-and:openrv64_timing_alu_rv64i_and"
    "rv64i-lui:openrv64_timing_alu_rv64i_lui"
    "rv64i-auipc:openrv64_timing_alu_rv64i_auipc"
)

rv64m_reports=(
    "rv64m-pipeline:openrv64_exec_rv64m"
)

run_report() {
    local report_name=$1
    local top_module=$2
    local report_path="$report_name.rpt"
    local report_display="$out_dir_display/$report_name.rpt"
    local verilog_sources=""
    local map_design=""
    local write_report=""
    local abc_options=""
    local flow=""

    if [[ "$report_name" == rv64m-* ]]; then
        verilog_sources="\"$repo_root/rtl/core/exec/alu/rv64-m.v\""
    else
        verilog_sources="\"$repo_root/rtl/core/exec/alu/rv64-i.v\" \"$repo_root/synth/alu/rv64-i-timing.v\""
    fi

    if [[ -n "$liberty" ]]; then
        if [[ -n "$abc_constr" ]]; then
            abc_options="$abc_options -constr \"$abc_constr\""
        fi
        if [[ -n "$abc_delay_ps" ]]; then
            abc_options="$abc_options -D $abc_delay_ps"
        fi
        map_design="dfflibmap -liberty \"$liberty\"; abc -liberty \"$liberty\"$abc_options; clean -purge;"
        write_report="stat -liberty \"$liberty\"; read_liberty -lib \"$liberty\"; check;"
    else
        map_design="abc -g simple; clean -purge;"
        write_report="tee -o \"$report_path\" stat; tee -a \"$report_path\" ltp -noff;"
    fi

    flow="read_verilog -sv -I$repo_root/rtl $verilog_sources; hierarchy -check -top $top_module; proc; flatten; opt; memory; opt; techmap; opt; $map_design $write_report"

    if [[ -n "$liberty" ]]; then
        "$yosys_bin" -Q -l "$report_path" -p "$flow" >/dev/null
        local delay_ps
        local area
        delay_ps=$(sed -n 's/.*Delay = *\([0-9.][0-9.]*\) ps.*/\1/p' "$report_path" | tail -1)
        area=$(sed -n "s/.*Chip area for module.*: *\([0-9.][0-9.]*\).*/\1/p" "$report_path" | tail -1)
        if [[ -n "$delay_ps" ]]; then
            local fmax_mhz
            fmax_mhz=$(awk -v delay_ps="$delay_ps" 'BEGIN { printf "%.1f", 1000000.0 / delay_ps }')
            printf '%-20s %8.2f ps  %7s MHz  area=%s (%s)\n' \
                "$report_name" "$delay_ps" "$fmax_mhz" "${area:-unknown}" "$report_display"
        else
            printf '%-20s technology mapped, no combinational path reported (%s)\n' \
                "$report_name" "$report_display"
        fi
    else
        "$yosys_bin" -Q -q -p "$flow"
        local depth
        depth=$(sed -n 's/.*Longest topological path.*length=\([0-9][0-9]*\).*/\1/p' "$report_path" | tail -1)
        printf '%-20s generic depth: %s gates (%s)\n' \
            "$report_name" "${depth:-unknown}" "$report_display"
    fi
}

if [[ "$report_set" == "all" || "$report_set" == "rv64i" ]]; then
    for report_spec in "${rv64i_reports[@]}"; do
        run_report "${report_spec%%:*}" "${report_spec#*:}"
    done
fi

if [[ "$report_set" == "all" || "$report_set" == "rv64m" ]]; then
    for report_spec in "${rv64m_reports[@]}"; do
        run_report "${report_spec%%:*}" "${report_spec#*:}"
    done
fi
