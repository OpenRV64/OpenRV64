#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export TZ=UTC

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/common.sh
source "${repo_root}/run/lib/common.sh"

log_root=$(realpath -m \
    "${OPENRV64_RUN_LOG_ROOT:-${repo_root}/run/log}")
record_makefile=scripts/make/run-record.mk

load_config() {
    local config_path=$1
    RUN_CONFIG_VERSION=
    RUN_TARGET=
    RUN_DESCRIPTION=
    RUN_JOBS=8
    RUN_TIMEOUT_SECONDS=259200
    RUN_REBUILD=0
    RUN_FOREGROUND=0
    RUN_BUILD_TARGETS=()
    RUN_RUN_TARGETS=()
    RUN_MAKE_ARGUMENTS=()
    RUN_RECORD_VARIABLES=()
    RUN_SOURCE_VARIABLES=()
    RUN_SOURCE_PATHS=()
    RUN_ARTIFACT_VARIABLES=()
    RUN_PASS_REGEX=
    RUN_RESULT_REGEX=
    # shellcheck disable=SC1090
    source "${config_path}"

    [[ ${RUN_CONFIG_VERSION} == 1 ]] ||
        openrv64_run_die 'RUN_CONFIG_VERSION must be 1'
    [[ ${RUN_TARGET} == bare-metal ]] ||
        openrv64_run_die "make backend requires RUN_TARGET=bare-metal"
    [[ -n ${RUN_DESCRIPTION} ]] ||
        openrv64_run_die 'RUN_DESCRIPTION is required'
    [[ ${RUN_JOBS} =~ ^[1-9][0-9]*$ ]] ||
        openrv64_run_die 'RUN_JOBS must be positive'
    [[ ${RUN_TIMEOUT_SECONDS} =~ ^[0-9]+$ ]] ||
        openrv64_run_die 'RUN_TIMEOUT_SECONDS must be nonnegative'
    [[ ${RUN_REBUILD} == 0 || ${RUN_REBUILD} == 1 ]] ||
        openrv64_run_die 'RUN_REBUILD must be 0 or 1'
    ((${#RUN_BUILD_TARGETS[@]})) ||
        openrv64_run_die 'RUN_BUILD_TARGETS must not be empty'
    ((${#RUN_RUN_TARGETS[@]})) ||
        openrv64_run_die 'RUN_RUN_TARGETS must not be empty'
    [[ -n ${RUN_PASS_REGEX} ]] ||
        openrv64_run_die 'RUN_PASS_REGEX is required'
    [[ -n ${RUN_RESULT_REGEX} ]] ||
        openrv64_run_die 'RUN_RESULT_REGEX is required'
}

record_artifacts() {
    local directory=$1
    shift
    local -a make_base=("$@")
    local artifact_record=${directory}/artifacts.txt
    local artifact_hashes=${directory}/artifacts.sha256
    local input_dir=${directory}/inputs
    local line variable path snapshot

    "${make_base[@]}" -f Makefile -f "${record_makefile}" \
        "RUN_ARTIFACT_VARIABLES=${RUN_ARTIFACT_VARIABLES[*]}" \
        openrv64-run-record-artifacts >"${artifact_record}" 2>&1
    mkdir -p "${input_dir}"
    : >"${artifact_hashes}"
    while IFS= read -r line; do
        [[ ${line} == *=* ]] || continue
        variable=${line%%=*}
        path=${line#*=}
        [[ -n ${path} ]] || continue
        if [[ -f ${path} ]]; then
            sha256sum -- "${path}" >>"${artifact_hashes}"
            snapshot=${input_dir}/${variable}-$(basename "${path}")
            cp --reflink=auto --preserve=mode,timestamps \
                "${path}" "${snapshot}"
        else
            printf 'MISSING  %s=%s\n' "${variable}" "${path}" \
                >>"${artifact_hashes}"
        fi
    done <"${artifact_record}"
}

worker() {
    local directory
    directory=$(realpath -m "$1")
    [[ -f ${directory}/manager.env ]] ||
        openrv64_run_die "missing manager.env: ${directory}"
    openrv64_run_load_manager "${directory}"
    # shellcheck disable=SC1090
    source "${directory}/backend.env"
    load_config "${config_snapshot}"
    mapfile -t RUN_MAKE_ARGUMENTS <"${directory}/make-arguments.txt"

    cd "${repo_root}"
    ulimit -c 0

    local build_log=${directory}/build.log
    local run_log=${directory}/run.log
    local status_file=${directory}/status
    local phase=setup
    local validation=not-run
    local sim_result=
    local heartbeat_pid=
    local started_utc
    started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    finish_worker() {
        local result=$?
        trap - EXIT
        if [[ -n ${heartbeat_pid} ]]; then
            kill "${heartbeat_pid}" 2>/dev/null || true
            wait "${heartbeat_pid}" 2>/dev/null || true
        fi
        {
            printf 'run_id=%s\n' "${run_id}"
            printf 'phase=%s\n' "${phase}"
            printf 'exit_code=%s\n' "${result}"
            printf 'sim_exit_code=%s\n' "${sim_result}"
            printf 'validation=%s\n' "${validation}"
            printf 'finished_utc=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'run_log=%s\n' "${run_log}"
        } >"${status_file}"
        openrv64_run_notify \
            "${run_id} finished: phase=${phase} exit=${result} validation=${validation}; ${run_log}" \
            "${task_name}"
        exit "${result}"
    }
    trap finish_worker EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    openrv64_run_heartbeat_loop "${directory}/heartbeat" &
    heartbeat_pid=$!

    openrv64_run_record_repository "${directory}"
    {
        printf 'OPENRV64_BARE_METAL_BUILD_RECORD_V1\n'
        printf 'run_id=%s\n' "${run_id}"
        printf 'started_utc=%s\n' "${started_utc}"
        printf 'description=%s\n' "${RUN_DESCRIPTION}"
        printf 'rebuild=%s\n' "${rebuild}"
        printf 'jobs=%s\n' "${jobs}"
        printf 'timeout_seconds=%s\n' "${timeout_seconds}"
        printf 'manifest_only=%s\n' "${manifest_only}"
        printf 'command=%s\n' "${recorded_command}"
    } >"${build_log}"

    local -a make_base=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL
        make --no-print-directory)
    local variable_list=${RUN_RECORD_VARIABLES[*]}
    local source_variable_list=${RUN_SOURCE_VARIABLES[*]}
    local source_path_list=${RUN_SOURCE_PATHS[*]}

    phase=config
    "${make_base[@]}" -f Makefile -f "${record_makefile}" \
        "${RUN_MAKE_ARGUMENTS[@]}" \
        "RUN_RECORD_VARIABLES=${variable_list}" \
        openrv64-run-record-config \
        >"${directory}/effective-config.txt" 2>&1
    "${make_base[@]}" -f Makefile -f "${record_makefile}" \
        "${RUN_MAKE_ARGUMENTS[@]}" \
        "RUN_SOURCE_VARIABLES=${source_variable_list}" \
        "RUN_SOURCE_PATHS=${source_path_list}" \
        openrv64-run-record-sources \
        >"${directory}/source-inputs.txt" 2>&1
    local provenance_input
    for provenance_input in "${config_snapshot}" run/run \
        run/lib/common.sh run/backends/make.sh scripts/make/run-record.mk; do
        if ! grep -Fqx -- "${provenance_input}" \
            "${directory}/source-inputs.txt"; then
            printf '%s\n' "${provenance_input}" \
                >>"${directory}/source-inputs.txt"
        fi
    done
    openrv64_run_write_hashes "${directory}/source-inputs.txt" \
        "${directory}/source-inputs.sha256"

    local infrastructure_dir=${directory}/inputs/run-infrastructure
    local infrastructure_input
    for infrastructure_input in run/run run/lib/common.sh \
        run/backends/make.sh scripts/make/run-record.mk; do
        mkdir -p "${infrastructure_dir}/$(dirname "${infrastructure_input}")"
        cp --reflink=auto --preserve=mode,timestamps \
            "${infrastructure_input}" \
            "${infrastructure_dir}/${infrastructure_input}"
    done

    if ((manifest_only == 1)); then
        phase=manifest
        validation=manifest
        sim_result=0
        exit 0
    fi

    mkdir -p "${log_root}"
    exec 9>"${log_root}/build.lock"
    flock 9

    phase=build
    local -a build_command=("${make_base[@]}" "-j${jobs}")
    [[ ${rebuild} == 0 ]] || build_command+=(-B)
    build_command+=("${RUN_MAKE_ARGUMENTS[@]}" "${RUN_BUILD_TARGETS[@]}")
    printf 'build_command=%s\n' \
        "$(openrv64_run_shell_join "${build_command[@]}")" >>"${build_log}"
    set +e
    "${build_command[@]}" 2>&1 | tee -a "${build_log}"
    local build_result=${PIPESTATUS[0]}
    set -e
    ((build_result == 0)) || exit "${build_result}"

    phase=run
    local -a run_command=("${make_base[@]}")
    [[ ${rebuild} == 0 ]] || run_command+=(-B)
    run_command+=("${RUN_MAKE_ARGUMENTS[@]}" "${RUN_RUN_TARGETS[@]}")
    {
        printf 'OPENRV64_BARE_METAL_RUN_RECORD_V1\n'
        printf 'run_id=%s\n' "${run_id}"
        printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'run_command=%s\n' \
            "$(openrv64_run_shell_join "${run_command[@]}")"
    } >"${run_log}"
    set +e
    stdbuf -oL -eL "${run_command[@]}" 2>&1 | tee -a "${run_log}"
    sim_result=${PIPESTATUS[0]}
    set -e

    phase=snapshot
    record_artifacts "${directory}" "${make_base[@]}" \
        "${RUN_MAKE_ARGUMENTS[@]}"
    flock -u 9
    exec 9>&-

    phase=validate
    if rg -q '%Fatal:|Assertion failed' "${run_log}"; then
        validation=fatal
    elif ((sim_result != 0)); then
        validation=simulator-error
    elif ! rg -q -- "${RUN_PASS_REGEX}" "${run_log}"; then
        validation=missing-pass
    elif ! rg -q -- "${RUN_RESULT_REGEX}" "${run_log}"; then
        validation=missing-result
    else
        validation=pass
    fi
    {
        printf 'sim_exit_code=%s\n' "${sim_result}"
        printf 'validation=%s\n' "${validation}"
        printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"${run_log}"
    if [[ ${validation} == pass ]]; then
        exit 0
    fi
    exit 1
}

start_run() {
    local config_path=${OPENRV64_RUN_CONFIG_PATH:-}
    local run_id=${OPENRV64_RUN_ID:-}
    local tmux_session=${OPENRV64_RUN_TMUX_SESSION:-}
    local task_name=${OPENRV64_RUN_TASK_NAME:-bare-metal}
    local recorded_command=${OPENRV64_RUN_RECORDED_COMMAND:-}
    local jobs rebuild foreground manifest_only=0
    local timeout_seconds
    local -a overrides=()

    [[ -f ${config_path} ]] ||
        openrv64_run_die 'OPENRV64_RUN_CONFIG_PATH is required'
    load_config "${config_path}"
    jobs=${RUN_JOBS}
    timeout_seconds=${OPENRV64_RUN_TIMEOUT_SECONDS:-${RUN_TIMEOUT_SECONDS}}
    rebuild=${RUN_REBUILD}
    foreground=${RUN_FOREGROUND}

    while (($#)); do
        case "$1" in
            --jobs) jobs=${2:?}; shift 2 ;;
            --timeout-seconds) timeout_seconds=${2:?}; shift 2 ;;
            --rebuild) rebuild=1; shift ;;
            --foreground) foreground=1; shift ;;
            --manifest-only) manifest_only=1; foreground=1; shift ;;
            [A-Za-z_][A-Za-z0-9_]*=*) overrides+=("$1"); shift ;;
            *) openrv64_run_die "unsupported bare-metal argument: $1" ;;
        esac
    done
    [[ ${jobs} =~ ^[1-9][0-9]*$ ]] ||
        openrv64_run_die '--jobs must be positive'
    [[ ${timeout_seconds} =~ ^[0-9]+$ ]] ||
        openrv64_run_die '--timeout-seconds must be nonnegative'
    [[ ${rebuild} == 0 || ${rebuild} == 1 ]] ||
        openrv64_run_die '--rebuild must be 0 or 1'
    [[ ${foreground} == 0 || ${foreground} == 1 ]] ||
        openrv64_run_die '--foreground must be 0 or 1'
    [[ ${run_id} =~ ^[A-Za-z0-9._-]+$ ]] ||
        openrv64_run_die "unsafe run ID: ${run_id}"
    [[ ${tmux_session} =~ ^[A-Za-z0-9_-]+$ ]] ||
        openrv64_run_die "unsafe tmux session: ${tmux_session}"

    mkdir -p "${log_root}"
    local directory=${log_root}/${run_id}
    if [[ -e ${directory} ]]; then
        directory=${directory}-$$
        run_id=${directory##*/}
        tmux_session=${tmux_session}-$$
    fi
    mkdir -p "${directory}"
    local config_snapshot=${directory}/run.cfg
    cp --reflink=auto --preserve=mode,timestamps \
        "${config_path}" "${config_snapshot}"
    printf '%s\n' "${RUN_DESCRIPTION}" >"${directory}/comment.txt"
    printf '%s\n' "${run_id}" >"${directory}/test-name.txt"
    printf '%s\n' "${RUN_MAKE_ARGUMENTS[@]}" "${overrides[@]}" \
        >"${directory}/make-arguments.txt"
    {
        printf 'run_id=%q\n' "${run_id}"
        printf 'run_dir=%q\n' "${directory}"
        printf 'run_target=%q\n' bare-metal
        printf 'backend=%q\n' run/backends/make.sh
        printf 'tmux_session=%q\n' "${tmux_session}"
        printf 'task_name=%q\n' "${task_name}"
        printf 'recorded_command=%q\n' "${recorded_command}"
        printf 'timeout_seconds=%q\n' "${timeout_seconds}"
        printf 'config_path=%q\n' "${config_path}"
        printf 'config_snapshot=%q\n' "${config_snapshot}"
    } >"${directory}/manager.env"
    {
        printf 'jobs=%q\n' "${jobs}"
        printf 'rebuild=%q\n' "${rebuild}"
        printf 'manifest_only=%q\n' "${manifest_only}"
        printf 'config_snapshot=%q\n' "${config_snapshot}"
        printf 'task_name=%q\n' "${task_name}"
    } >"${directory}/backend.env"

    if ((foreground == 1)); then
        openrv64_run_with_timeout "${timeout_seconds}" "${directory}" \
            "${task_name}" "${repo_root}/run/backends/make.sh" \
            _worker "${directory}"
        return
    fi
    command -v tmux >/dev/null 2>&1 ||
        openrv64_run_die 'tmux is not installed'
    local worker_command
    worker_command=$(openrv64_run_shell_join env \
        "OPENRV64_RUN_LOG_ROOT=${log_root}" \
        "${repo_root}/run/backends/make.sh" _timed_worker "${directory}")
    tmux new-session -d -s "${tmux_session}" -c "${repo_root}" \
        "${worker_command}"
    openrv64_run_notify "Started bare-metal run ${run_id}; ${directory}" \
        "${task_name}"
    printf 'run_id=%s\nrun_dir=%s\ntmux_session=%s\n' \
        "${run_id}" "${directory}" "${tmux_session}"
}

case "${1:-}" in
    start) shift; start_run "$@" ;;
    _worker) shift; worker "$@" ;;
    _timed_worker)
        shift
        openrv64_run_load_manager "$1"
        openrv64_run_with_timeout "${timeout_seconds:-259200}" "$1" \
            "${task_name:-bare-metal}" \
            "${repo_root}/run/backends/make.sh" _worker "$1"
        ;;
    *) openrv64_run_die 'make backend requires start or _worker' ;;
esac
