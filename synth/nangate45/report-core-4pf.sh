#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

variant=${1:-}
yosys_bin=${YOSYS:-yosys}
liberty=${LIBERTY:-$repo_root/sim/pdk/nangate45/NangateOpenCellLibrary_typical.lib}
abc_constr=${ABC_CONSTR:-$script_dir/abc.constr}
out_root=${OUT_DIR:-$repo_root/sim/yosys/core-4pf-nangate45}
resource_jobs=${RESOURCE_JOBS:-16}
register_issue_select=${REGISTER_ISSUE_SELECT:-0}

case "$variant" in
    fd)
        enable_fd=1
        ;;
    nofd)
        enable_fd=0
        ;;
    *)
        echo "usage: $0 {fd|nofd}" >&2
        exit 2
        ;;
esac

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi
if [[ ! "$resource_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: RESOURCE_JOBS must be a positive integer" >&2
    exit 2
fi
if (( resource_jobs > 32 )); then
    resource_jobs=32
fi
if [[ "$register_issue_select" != 0 && "$register_issue_select" != 1 ]]; then
    echo "error: REGISTER_ISSUE_SELECT must be 0 or 1" >&2
    exit 2
fi

for path_var in liberty abc_constr out_root; do
    path=${!path_var}
    if [[ "$path" != /* ]]; then
        printf -v "$path_var" '%s/%s' "$repo_root" "$path"
    fi
done

# Direct invocation is self-contained: fetch the pinned external dependency if
# absent, and re-check its digest if it is already cached.
CURL=${CURL:-curl} "$script_dir/fetch-liberty.sh" "$liberty"
if [[ ! -f "$abc_constr" ]]; then
    echo "error: ABC constraint file does not exist: $abc_constr" >&2
    exit 2
fi

out_dir="$out_root/$variant"
worker_dir="$out_dir/workers-scl-map"
mkdir -p "$worker_dir"

mapfile -t core_sources < <(
    cd "$repo_root"
    rg --files rtl/core -g '*.v' \
        -g '!rtl/core/exec/vec/**' \
        -g '!rtl/core/regs/rv64-i-vec.v' | sort
)
mapfile -t cache_sources < <(
    cd "$repo_root"
    rg --files rtl/cache/l1 -g '*.v' | sort
)
source_args=()
for source in "${core_sources[@]}" "${cache_sources[@]}"; do
    source_args+=("$repo_root/$source")
done
source_list=$(printf ' "%s"' "${source_args[@]}")

elaborate="read_verilog -sv -defer -DSYNTHESIS -I$repo_root/rtl$source_list; \
hierarchy -check -top openrv64_top_4pf \
    -chparam ENABLE_RV64F $enable_fd \
    -chparam ENABLE_RV64D $enable_fd \
    -chparam ENABLE_PIPELINED_FP_MULTIPLY 1 \
    -chparam RETIRE_DEPTH 16 \
    -chparam ENABLE_ISSUE_WINDOW 1 \
    -chparam ENABLE_SPECULATION_WINDOW 1 \
    -chparam REGISTER_ISSUE_SELECT $register_issue_select \
    -chparam ENABLE_L1I 0 \
    -chparam ENABLE_L1D 0 \
    -chparam ENABLE_TRACE 0;"

# Retain normal core reporting seams. The backend and decode wrappers are not
# retained: flattening both into the core is required for ENABLE_RV64F/D=0 to
# propagate into the extension sidecar and remove unreachable F/D hardware.
partition_boundaries="
setattr -set keep_hierarchy 1 */c:u_core;
setattr -set keep_hierarchy 1 */c:g_fetch_axi.u_fetch;
setattr -set keep_hierarchy 1 */c:u_bp;
setattr -set keep_hierarchy 1 */c:u_bp_target;
setattr -set keep_hierarchy 1 */c:u_csrs;
setattr -set keep_hierarchy 1 */c:u_vector;
setattr -set keep_hierarchy 1 */t:*openrv64_core_bus*;
setattr -set keep_hierarchy 1 */t:*openrv64_core_ccx_bus*;
setattr -set keep_hierarchy 1 */t:*openrv64_bus_tlb*;
setattr -set keep_hierarchy 1 */t:*openrv64_bus_ptw*;
setattr -set keep_hierarchy 1 */c:u_dispatch;
setattr -set keep_hierarchy 1 */c:u_gpr;
setattr -set keep_hierarchy 1 */c:u_ex0;
setattr -set keep_hierarchy 1 */c:u_ex1;
setattr -set keep_hierarchy 1 */c:u_mem0;
setattr -set keep_hierarchy 1 */c:u_mem1;
setattr -set keep_hierarchy 1 */c:u_retire_queue;
setattr -set keep_hierarchy 1 */c:u_retire_records;
setattr -set keep_hierarchy 1 */c:u_retire;
select -clear;"

pre_stat="$out_dir/pre-map-stat.json"
hierarchy_report="$out_dir/hierarchy.rpt"
memory_report="$out_dir/memories.rpt"
checkpoint="$out_dir/pre-map.il"
map_stat="$out_dir/mapped-stat.json"
log="$out_dir/yosys.log"

pre_map="proc; flatten -noscopeinfo; opt; memory -nomap; opt; techmap; opt; \
dfflibmap -liberty \"$liberty\";"

echo "[$variant] elaborating cacheless 4PF core and preparing partitions"
"$yosys_bin" -Q -l "$log" -p "$elaborate $partition_boundaries $pre_map \
    tee -o \"$pre_stat\" stat -liberty \"$liberty\" -json; \
    tee -o \"$hierarchy_report\" dump */a:keep_hierarchy=1; \
    tee -o \"$memory_report\" dump -m */t:\$mem_v2; \
    write_rtlil \"$checkpoint\"; \
    read_liberty -lib \"$liberty\"; check;" >/dev/null

echo "[$variant] mapping retained partitions with $resource_jobs workers"
python3 "$repo_root/synth/core/parallel_map.py" \
    --yosys "$yosys_bin" \
    --checkpoint "$checkpoint" \
    --pre-stat "$pre_stat" \
    --hierarchy "$hierarchy_report" \
    --liberty "$liberty" \
    --constraint "$abc_constr" \
    --out-stat "$map_stat" \
    --worker-dir "$worker_dir" \
    --jobs "$resource_jobs" \
    --abc-script "$script_dir/abc-map.script"

python3 "$script_dir/summarize-core-4pf.py" \
    --variant "$variant" \
    --register-issue-select "$register_issue_select" \
    --stat "$map_stat" \
    --liberty "$liberty" \
    --worker-dir "$worker_dir" \
    --out-dir "$out_dir"
