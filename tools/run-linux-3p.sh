#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export TZ=UTC

wrapper_path=${BASH_SOURCE[0]:-$0}
if [[ "${OPENRV64_LINUX_RUN_BUFFERED:-0}" != 1 ]]; then
    wrapper_source=$(<"${wrapper_path}")
    exec env OPENRV64_LINUX_RUN_BUFFERED=1 \
        bash -c "${wrapper_source}" "${wrapper_path}" "$@"
fi
repo_root=$(cd "$(dirname "${wrapper_path}")/.." && pwd)
cd "${repo_root}"

usage() {
    cat <<'EOF'
Usage:
  tools/run-linux-3p.sh --name NAME --comment TEXT \
    [options] [-jN] [NAME=value ...] [-- +plusarg ...]

Build and run the full 3P OpenSBI/Linux simulation while retaining a complete
configuration and provenance record.  Make-style NAME=value arguments are
passed to both configuration resolution and the build.

Options:
  --name NAME        Required human-readable test name.
  --comment TEXT     Required explanation of purpose and relevant repo state.
  --tmux-session NAME
                     Launch this invocation in a detached named tmux session.
  --build-only       Stop after a successful build and artifact fingerprint.
  --manifest-only    Resolve and record configuration without building.
  --no-force         Permit an incremental build instead of the default -B.
  --no-checkpoint    Do not save a checkpoint during the full run.
  --checkpoint-exit  Exit immediately after saving the checkpoint.
  -h, --help         Show this help.

Wrapper defaults, unless overridden with NAME=value:
  LINUX_MAX_CYCLES=200000000
  OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES=50000000
  OPENSBI_3P_PLATFORM_CHECKPOINT=<run-directory>/linux.vls
  LINUX_IMAGE_MEMH=<run-directory>/linux-image.memh

Examples:
  tools/run-linux-3p.sh \
    --name zicclsm-sequential-l1i \
    --comment "Full Linux boot with Zicclsm image and new L1I prefetch RTL." \
    -j8 \
    LINUX_IMAGE=sw/Image.Zicclsm \
    OPENSBI_3P_ENABLE_ZICCLSM=1 \
    OPENSBI_3P_PLATFORM_BP_TYPE=8 \
    OPENSBI_3P_PLATFORM_RETIRE_DEPTH=32 \
    OPENSBI_3P_PLATFORM_DDR3_ENABLE=1

  tools/run-linux-3p.sh \
    --name manifest-check \
    --comment "Resolve the proposed configuration without building it." \
    --manifest-only \
    LINUX_IMAGE=sw/Image.Zicclsm OPENSBI_3P_ENABLE_ZICCLSM=1

  tools/run-linux-3p.sh \
    --tmux-session zicclsm-boot \
    --name zicclsm-sequential-l1i \
    --comment "Attach with: tmux attach-session -t zicclsm-boot" \
    LINUX_IMAGE=sw/Image.Zicclsm OPENSBI_3P_ENABLE_ZICCLSM=1
EOF
}

shell_join() {
    local output=
    local quoted
    local argument
    for argument in "$@"; do
        printf -v quoted '%q' "${argument}"
        if [[ -n "${output}" ]]; then
            output+=" "
        fi
        output+="${quoted}"
    done
    printf '%s' "${output}"
}

original_arguments=("$@")
test_name=
test_comment=
tmux_session=
build_enabled=1
run_enabled=1
force_build=1
checkpoint_enabled=1
checkpoint_exit=0
make_arguments=()
simulator_arguments=()

while (($#)); do
    case "$1" in
        --name)
            if (($# < 2)); then
                echo "run-linux-3p.sh: --name requires a value" >&2
                exit 2
            fi
            test_name=$2
            shift 2
            ;;
        --comment)
            if (($# < 2)); then
                echo "run-linux-3p.sh: --comment requires a value" >&2
                exit 2
            fi
            test_comment=$2
            shift 2
            ;;
        --tmux-session)
            if (($# < 2)); then
                echo "run-linux-3p.sh: --tmux-session requires a value" >&2
                exit 2
            fi
            tmux_session=$2
            shift 2
            ;;
        --build-only)
            run_enabled=0
            shift
            ;;
        --manifest-only)
            build_enabled=0
            run_enabled=0
            shift
            ;;
        --no-force)
            force_build=0
            shift
            ;;
        --no-checkpoint)
            checkpoint_enabled=0
            shift
            ;;
        --checkpoint-exit)
            checkpoint_exit=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            simulator_arguments=("$@")
            break
            ;;
        -j|-j[0-9]*|--jobs|--jobs=*)
            make_arguments+=("$1")
            if [[ "$1" == "-j" || "$1" == "--jobs" ]]; then
                if (($# < 2)); then
                    echo "run-linux-3p.sh: $1 requires a value" >&2
                    exit 2
                fi
                make_arguments+=("$2")
                shift
            fi
            shift
            ;;
        [A-Za-z_][A-Za-z0-9_]*=*)
            make_arguments+=("$1")
            shift
            ;;
        -*)
            echo "run-linux-3p.sh: unsupported option: $1" >&2
            exit 2
            ;;
        *)
            echo "run-linux-3p.sh: expected NAME=value, got: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "${test_name}" ]]; then
    echo "run-linux-3p.sh: --name is required" >&2
    exit 2
fi
if [[ "${test_name}" == *$'\n'* || "${test_name}" == *$'\r'* ]]; then
    echo "run-linux-3p.sh: --name must be a single line" >&2
    exit 2
fi
if [[ -z "${test_comment}" ]]; then
    echo "run-linux-3p.sh: --comment is required" >&2
    exit 2
fi
if [[ -n "${tmux_session}" &&
      ! "${tmux_session}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "run-linux-3p.sh: --tmux-session must match [A-Za-z0-9_-]+" >&2
    exit 2
fi

for argument in "${simulator_arguments[@]}"; do
    if [[ "${argument}" != +* ]]; then
        echo "run-linux-3p.sh: simulator argument must start with +: ${argument}" >&2
        exit 2
    fi
done

if [[ -n "${tmux_session}" &&
      "${OPENRV64_LINUX_RUN_TMUX_REENTRY:-0}" != 1 ]]; then
    if ! command -v tmux >/dev/null 2>&1; then
        echo "run-linux-3p.sh: tmux is not installed" >&2
        exit 127
    fi
    if tmux has-session -t "=${tmux_session}" 2>/dev/null; then
        echo "run-linux-3p.sh: tmux session already exists: ${tmux_session}" \
            >&2
        exit 2
    fi

    tmux_command=$(
        shell_join env OPENRV64_LINUX_RUN_TMUX_REENTRY=1 \
            "${repo_root}/tools/run-linux-3p.sh" \
            "${original_arguments[@]}"
    )
    tmux new-session -d -s "${tmux_session}" -c "${repo_root}" \
        "${tmux_command}"
    printf 'run-linux-3p.sh: launched tmux session: %s\n' \
        "${tmux_session}" >&2
    printf 'run-linux-3p.sh: attach: tmux attach-session -t %s\n' \
        "${tmux_session}" >&2
    exit 0
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
name_slug=$(
    printf '%s' "${test_name}" |
        tr -cs 'A-Za-z0-9._-' '-' |
        sed 's/^-*//; s/-*$//'
)
if [[ -z "${name_slug}" ]]; then
    echo "run-linux-3p.sh: --name has no filesystem-safe characters" >&2
    exit 2
fi
run_id="${timestamp}-${name_slug}"
run_dir="build/runs/linux-3p/${run_id}"
if [[ -e "${run_dir}" ]]; then
    run_id="${run_id}-$$"
    run_dir="build/runs/linux-3p/${run_id}"
fi
mkdir -p "${run_dir}"

build_log="${run_dir}/build.log"
run_log="${run_dir}/run.log"
status_file="${run_dir}/status"
config_file="${run_dir}/effective-config.txt"
input_file="${run_dir}/source-inputs.txt"
input_hash_file="${run_dir}/source-inputs.sha256"
artifact_hash_file="${run_dir}/artifacts.sha256"
git_status_file="${run_dir}/git-status.txt"
git_diff_file="${run_dir}/worktree.patch"
test_name_file="${run_dir}/test-name.txt"
test_comment_file="${run_dir}/comment.txt"
input_snapshot_dir="${run_dir}/inputs"
touch "${build_log}"
printf '%s\n' "${test_name}" >"${test_name_file}"
printf '%s\n' "${test_comment}" >"${test_comment_file}"

phase=setup
script_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)

finish_record() {
    local result=$?
    trap - EXIT
    {
        printf 'record.footer.phase=%s\n' "${phase}"
        printf 'record.footer.exit_code=%s\n' "${result}"
        printf 'record.footer.finished_utc=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"${build_log}"
    {
        printf 'run_id=%s\n' "${run_id}"
        printf 'phase=%s\n' "${phase}"
        printf 'exit_code=%s\n' "${result}"
        printf 'build_log=%s\n' "${build_log}"
        if [[ -e "${run_log}" ]]; then
            printf 'run_log=%s\n' "${run_log}"
        fi
    } >"${status_file}"
    if ((result == 0)); then
        echo "run-linux-3p.sh: complete: ${run_dir}" >&2
    else
        echo "run-linux-3p.sh: failed in ${phase} (exit ${result}): ${run_dir}" >&2
    fi
    exit "${result}"
}
trap finish_record EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

has_assignment() {
    local wanted=$1
    local argument
    for argument in "${make_arguments[@]}"; do
        if [[ "${argument}" == "${wanted}="* ]]; then
            return 0
        fi
    done
    return 1
}

wrapper_defaults=()
if ! has_assignment LINUX_MAX_CYCLES; then
    wrapper_defaults+=("LINUX_MAX_CYCLES=200000000")
fi
if ! has_assignment OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES; then
    wrapper_defaults+=(
        "OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES=50000000"
    )
fi
if ! has_assignment OPENSBI_3P_PLATFORM_CHECKPOINT; then
    wrapper_defaults+=(
        "OPENSBI_3P_PLATFORM_CHECKPOINT=${run_dir}/linux.vls"
    )
fi
if ! has_assignment LINUX_IMAGE_MEMH; then
    wrapper_defaults+=("LINUX_IMAGE_MEMH=${run_dir}/linux-image.memh")
fi
make_arguments+=("${wrapper_defaults[@]}")

jobs_present=0
for argument in "${make_arguments[@]}"; do
    case "${argument}" in
        -j|-j[0-9]*|--jobs|--jobs=*)
            jobs_present=1
            ;;
    esac
done
if ((jobs_present == 0)); then
    make_arguments=("-j8" "${make_arguments[@]}")
fi

first_line() {
    "$@" 2>&1 | sed -n '1p'
}

git rev-parse HEAD >"${run_dir}/git-head.txt"
git status --short >"${git_status_file}"
git diff --binary HEAD >"${git_diff_file}"

{
    printf 'OPENRV64_LINUX_3P_BUILD_RECORD_V1\n'
    printf 'record.run_id=%s\n' "${run_id}"
    printf 'record.started_utc=%s\n' "${script_start}"
    printf 'record.repository=%s\n' "${repo_root}"
    printf 'record.wrapper=%s\n' "tools/run-linux-3p.sh"
    printf 'record.wrapper_command=%s\n' \
        "$(shell_join tools/run-linux-3p.sh "${original_arguments[@]}")"
    printf 'record.tmux_session=%s\n' "${tmux_session}"
    printf 'record.test_name=%s\n' "${test_name}"
    printf 'record.test_name_file=%s\n' "${test_name_file}"
    printf 'record.test_comment_file=%s\n' "${test_comment_file}"
    printf 'record.test_comment_sha256=%s\n' \
        "$(sha256sum "${test_comment_file}" | awk '{print $1}')"
    printf 'record.test_comment_begin\n'
    sed -n 'p' "${test_comment_file}"
    printf 'record.test_comment_end\n'
    printf 'record.build_mode=%s\n' \
        "$([[ ${force_build} == 1 ]] && printf forced || printf incremental)"
    printf 'record.build_enabled=%s\n' "${build_enabled}"
    printf 'record.run_enabled=%s\n' "${run_enabled}"
    printf 'record.checkpoint_enabled=%s\n' "${checkpoint_enabled}"
    printf 'record.checkpoint_exit=%s\n' "${checkpoint_exit}"
    printf 'record.git_head=%s\n' "$(sed -n '1p' "${run_dir}/git-head.txt")"
    printf 'record.git_status_sha256=%s\n' \
        "$(sha256sum "${git_status_file}" | awk '{print $1}')"
    printf 'record.git_diff_sha256=%s\n' \
        "$(sha256sum "${git_diff_file}" | awk '{print $1}')"
    printf 'record.host=%s\n' "$(uname -a)"
    printf 'record.umask=%s\n' "$(umask)"
    printf 'record.path=%s\n' "${PATH}"
    printf 'record.tool.git=%s\n' "$(first_line git --version)"
    printf 'record.tool.make=%s\n' "$(first_line make --version)"
    printf 'record.tool.verilator=%s\n' "$(first_line verilator --version)"
    printf 'record.tool.python=%s\n' "$(first_line python3 --version)"
    printf 'record.tool.riscv_linux_gcc=%s\n' \
        "$(first_line riscv64-linux-gnu-gcc --version)"
    printf 'record.tool.riscv_elf_gcc=%s\n' \
        "$(first_line riscv64-elf-gcc --version)"
    printf 'record.git_status_begin\n'
    sed -n 'p' "${git_status_file}"
    printf 'record.git_status_end\n'
    printf 'record.wrapper_defaults_begin\n'
    printf '%s\n' "${wrapper_defaults[@]}"
    printf 'record.wrapper_defaults_end\n'
} >>"${build_log}"

echo "run-linux-3p.sh: records: ${run_dir}" >&2

make_base=(
    env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL
    make --no-print-directory
)
record_makefile="scripts/make/linux-run-record.mk"

phase=config
config_command=(
    "${make_base[@]}"
    -f Makefile
    -f "${record_makefile}"
    "${make_arguments[@]}"
    openrv64-linux-run-config
)
printf 'record.config_command=%s\n' \
    "$(shell_join "${config_command[@]}")" >>"${build_log}"

set +e
"${config_command[@]}" >"${config_file}" 2>&1
config_result=$?
set -e
{
    printf 'record.effective_config_begin\n'
    sed -n 'p' "${config_file}"
    printf 'record.effective_config_end\n'
    printf 'record.config_exit_code=%s\n' "${config_result}"
} >>"${build_log}"
if ((config_result != 0)); then
    exit "${config_result}"
fi

config_value() {
    local key=$1
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            exit
        }
    ' "${config_file}"
}

simulator=$(config_value OPENSBI_3P_PLATFORM_VERILATOR_BUILD)
artifact_dir=$(config_value OPENSBI_ARTIFACT_DIR)
source_dir=$(config_value OPENSBI_SOURCE_DIR)
linux_image=$(config_value LINUX_IMAGE)
linux_image_memh=$(config_value LINUX_IMAGE_MEMH)
linux_image_words=$(config_value LINUX_IMAGE_WORDS)
linux_max_cycles=$(config_value LINUX_MAX_CYCLES)
checkpoint_path=$(config_value OPENSBI_3P_PLATFORM_CHECKPOINT)
checkpoint_cycles=$(
    config_value OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES
)
verilator_threads=$(
    config_value OPENSBI_3P_PLATFORM_VERILATOR_THREADS
)

required_values=(
    simulator
    artifact_dir
    source_dir
    linux_image
    linux_image_memh
    linux_image_words
    linux_max_cycles
    checkpoint_path
    checkpoint_cycles
    verilator_threads
)
for value_name in "${required_values[@]}"; do
    if [[ -z "${!value_name}" ]]; then
        echo "run-linux-3p.sh: missing effective value: ${value_name}" \
            | tee -a "${build_log}" >&2
        exit 2
    fi
done

input_command=(
    "${make_base[@]}"
    -f Makefile
    -f "${record_makefile}"
    "${make_arguments[@]}"
    openrv64-linux-run-inputs
)
printf 'record.input_command=%s\n' \
    "$(shell_join "${input_command[@]}")" >>"${build_log}"

set +e
"${input_command[@]}" >"${input_file}" 2>&1
input_result=$?
set -e
if ((input_result != 0)); then
    {
        printf 'record.input_resolution_begin\n'
        sed -n 'p' "${input_file}"
        printf 'record.input_resolution_end\n'
        printf 'record.input_exit_code=%s\n' "${input_result}"
    } >>"${build_log}"
    exit "${input_result}"
fi

: >"${input_hash_file}"
while IFS= read -r input; do
    if [[ -z "${input}" || "${input}" == OPENRV64_LINUX_RUN_INPUTS_V1 ]]; then
        continue
    fi
    if [[ -f "${input}" ]]; then
        sha256sum -- "${input}" >>"${input_hash_file}"
    else
        printf 'MISSING  %s\n' "${input}" >>"${input_hash_file}"
    fi
done <"${input_file}"

{
    printf 'record.source_inputs=%s\n' "${input_hash_file}"
    printf 'record.source_inputs_sha256=%s\n' \
        "$(sha256sum "${input_hash_file}" | awk '{print $1}')"
    printf 'record.source_input_count=%s\n' \
        "$(wc -l <"${input_hash_file}")"
    printf 'record.manifest_complete\n'
} >>"${build_log}"

if ((build_enabled == 0)); then
    phase=manifest
    exit 0
fi

phase=build
build_command=("${make_base[@]}")
if ((force_build == 1)); then
    build_command+=(-B)
fi
build_command+=(
    "${make_arguments[@]}"
    "${simulator}"
    opensbi
    "${linux_image_memh}"
)
printf 'record.build_command=%s\n' \
    "$(shell_join "${build_command[@]}")" >>"${build_log}"
printf 'record.build_started_utc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${build_log}"

lock_file="build/runs/linux-3p/build.lock"
exec 9>"${lock_file}"
echo "run-linux-3p.sh: waiting for build lock: ${lock_file}" >&2
flock 9
printf 'record.build_lock_acquired_utc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${build_log}"

set +e
"${build_command[@]}" 2>&1 | tee -a "${build_log}"
build_result=${PIPESTATUS[0]}
set -e

{
    printf 'record.build_exit_code=%s\n' "${build_result}"
    printf 'record.build_finished_utc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >>"${build_log}"
if ((build_result != 0)); then
    flock -u 9
    exec 9>&-
    exit "${build_result}"
fi

artifact_paths=(
    "${linux_image_memh}"
)

mkdir -p "${input_snapshot_dir}"
snapshot_simulator="${input_snapshot_dir}/opensbi_3p_platform_tb"
snapshot_linux_image="${input_snapshot_dir}/linux-image.bin"
snapshot_trampoline="${input_snapshot_dir}/trampoline.memh"
snapshot_firmware="${input_snapshot_dir}/fw_jump.memh"
snapshot_firmware_elf="${input_snapshot_dir}/fw_jump.elf"
snapshot_dtb="${input_snapshot_dir}/openrv64-3p.dtb"
snapshot_dtb_memh="${input_snapshot_dir}/openrv64-3p-dtb.memh"
cp --reflink=auto --preserve=mode,timestamps \
    "${simulator}" "${snapshot_simulator}"
cp --reflink=auto --preserve=mode,timestamps \
    "${linux_image}" "${snapshot_linux_image}"
cp --reflink=auto --preserve=mode,timestamps \
    "${artifact_dir}/trampoline.memh" "${snapshot_trampoline}"
cp --reflink=auto --preserve=mode,timestamps \
    "${artifact_dir}/fw_jump.memh" "${snapshot_firmware}"
cp --reflink=auto --preserve=mode,timestamps \
    "${artifact_dir}/fw_jump.elf" "${snapshot_firmware_elf}"
cp --reflink=auto --preserve=mode,timestamps \
    "${artifact_dir}/openrv64-3p.dtb" "${snapshot_dtb}"
cp --reflink=auto --preserve=mode,timestamps \
    "${artifact_dir}/openrv64-3p-dtb.memh" "${snapshot_dtb_memh}"
artifact_paths+=(
    "${snapshot_simulator}"
    "${snapshot_linux_image}"
    "${snapshot_trampoline}"
    "${snapshot_firmware}"
    "${snapshot_firmware_elf}"
    "${snapshot_dtb}"
    "${snapshot_dtb_memh}"
)
: >"${artifact_hash_file}"
for artifact in "${artifact_paths[@]}"; do
    if [[ -f "${artifact}" ]]; then
        sha256sum -- "${artifact}" >>"${artifact_hash_file}"
    else
        printf 'MISSING  %s\n' "${artifact}" >>"${artifact_hash_file}"
    fi
done

{
    printf 'record.artifacts=%s\n' "${artifact_hash_file}"
    printf 'record.artifacts_sha256=%s\n' \
        "$(sha256sum "${artifact_hash_file}" | awk '{print $1}')"
    printf 'record.configured_simulator=%s\n' "${simulator}"
    printf 'record.snapshot_simulator=%s\n' "${snapshot_simulator}"
    printf 'record.input_snapshot_dir=%s\n' "${input_snapshot_dir}"
    if [[ -d "${source_dir}/.git" ]]; then
        printf 'record.opensbi_git_head=%s\n' \
            "$(git -C "${source_dir}" rev-parse HEAD)"
        printf 'record.opensbi_git_status_begin\n'
        git -C "${source_dir}" status --short
        printf 'record.opensbi_git_status_end\n'
    fi
} >>"${build_log}"

flock -u 9
exec 9>&-
printf 'record.build_lock_released_utc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${build_log}"

if ((run_enabled == 0)); then
    phase=build
    exit 0
fi

phase=run
run_command=(
    "${snapshot_simulator}"
    "+trampoline_memh=${snapshot_trampoline}"
    "+firmware_memh=${snapshot_firmware}"
    "+payload_memh=${linux_image_memh}"
    "+payload_words=${linux_image_words}"
    "+fdt_memh=${snapshot_dtb_memh}"
    +linux_mode
    "+max_cycles=${linux_max_cycles}"
    "+verilator_threads=${verilator_threads}"
)
if ((checkpoint_enabled == 1)); then
    mkdir -p "$(dirname "${checkpoint_path}")"
    run_command+=(
        "+checkpoint=${checkpoint_path}"
        "+checkpoint_cycles=${checkpoint_cycles}"
    )
    if ((checkpoint_exit == 1)); then
        run_command+=(+checkpoint_exit)
    fi
fi
run_command+=("${simulator_arguments[@]}")

{
    printf 'OPENRV64_LINUX_3P_RUN_RECORD_V1\n'
    printf 'record.run_id=%s\n' "${run_id}"
    printf 'record.test_name=%s\n' "${test_name}"
    printf 'record.test_comment_file=%s\n' "${test_comment_file}"
    printf 'record.test_comment_sha256=%s\n' \
        "$(sha256sum "${test_comment_file}" | awk '{print $1}')"
    printf 'record.test_comment_begin\n'
    sed -n 'p' "${test_comment_file}"
    printf 'record.test_comment_end\n'
    printf 'record.started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'record.command=%s\n' "$(shell_join "${run_command[@]}")"
    printf 'record.build_log=%s\n' "${build_log}"
    printf 'record.effective_config=%s\n' "${config_file}"
    printf 'record.artifacts=%s\n' "${artifact_hash_file}"
} >"${run_log}"

set +e
stdbuf -oL -eL "${run_command[@]}" 2>&1 | tee -a "${run_log}"
run_result=${PIPESTATUS[0]}
set -e

prompt_seen=0
pass_seen=0
if grep -Fq 'openrv64# ' "${run_log}"; then
    prompt_seen=1
fi
if grep -Fq 'PASS' "${run_log}"; then
    pass_seen=1
fi
{
    printf 'record.exit_code=%s\n' "${run_result}"
    printf 'record.prompt_seen=%s\n' "${prompt_seen}"
    printf 'record.pass_seen=%s\n' "${pass_seen}"
    printf 'record.finished_utc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >>"${run_log}"

exit "${run_result}"
