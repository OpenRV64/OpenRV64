#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export TZ=UTC

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
log_root=$(realpath -m \
    "${OPENRV64_RUN_LOG_ROOT:-${script_dir}/log}")

die() {
    printf 'run/run.sh: %s\n' "$*" >&2
    exit 2
}

resolve_instance() {
    local requested=$1
    local candidate=

    if [[ ${requested} == latest ]]; then
        candidate=$(find "${log_root}" -mindepth 2 -maxdepth 2 \
            -name manager.env -printf '%T@ %h\n' 2>/dev/null |
            sort -nr | sed -n '1s/^[^ ]* //p')
    elif [[ -d ${requested} ]]; then
        candidate=$(realpath -m "${requested}")
    elif [[ -d ${log_root}/${requested} ]]; then
        candidate=$(realpath -m "${log_root}/${requested}")
    else
        candidate=$(find "${log_root}" -mindepth 1 -maxdepth 1 \
            -type d -name "${requested}-*" -printf '%T@ %p\n' \
            2>/dev/null | sort -nr | sed -n '1s/^[^ ]* //p')
    fi

    [[ -n ${candidate} ]] || die "run instance not found: ${requested}"
    case "${candidate}/" in
        "${log_root}/"*/) ;;
        *) die "run instance is outside ${log_root}: ${candidate}" ;;
    esac
    [[ -f ${candidate}/manager.env ]] ||
        die "run instance lacks manager.env: ${candidate}"
    printf '%s' "${candidate}"
}

status_instance() {
    local directory
    directory=$(resolve_instance "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"

    local now state phase activity_file activity_age heartbeat_age
    local latest checkpoint_file
    now=$(date -u +%s)
    state=pending
    phase=setup
    activity_file=
    activity_age=
    heartbeat_age=

    if [[ -f ${directory}/status ]]; then
        state=finished
        phase=$(sed -n 's/^phase=//p' "${directory}/status" | head -1)
        [[ -n ${phase} ]] || phase=unknown
    else
        if [[ -f ${directory}/run.log ]]; then
            phase=run
            activity_file=${directory}/run.log
        elif [[ -f ${directory}/build.log ]]; then
            phase=build
            activity_file=${directory}/build.log
        fi

        if [[ -f ${directory}/heartbeat ]]; then
            heartbeat_age=$((now - $(stat -c %Y "${directory}/heartbeat")))
        fi
        if [[ -n ${activity_file} ]]; then
            activity_age=$((now - $(stat -c %Y "${activity_file}")))
        fi

        if [[ -n ${heartbeat_age} && ${heartbeat_age} -le 120 ]]; then
            state=active
        elif [[ -n ${activity_age} && ${activity_age} -le 900 ]]; then
            # Compatibility for workers launched before heartbeat support.
            state=active
        elif [[ -n ${activity_file} ]]; then
            state=stale
        fi
    fi

    printf 'run_id=%s\n' "${run_id}"
    printf 'state=%s\n' "${state}"
    printf 'phase=%s\n' "${phase}"
    printf 'harts=%s\n' "${harts}"
    printf 'threads=%s\n' "${threads}"
    [[ -z ${heartbeat_age} ]] ||
        printf 'heartbeat_age_seconds=%s\n' "${heartbeat_age}"
    [[ -z ${activity_age} ]] ||
        printf 'activity_age_seconds=%s\n' "${activity_age}"

    latest=$(rg 'OPENSBI_4H_PROGRESS|LINUX_SMP_ONLINE|CHECKPOINT SAVED|linux_panic=1|Kernel panic|openrv64#|PASS:|%Fatal:|Assertion failed' \
        "${directory}/run.log" 2>/dev/null | tail -1 || true)
    [[ -z ${latest} ]] || printf 'latest=%s\n' "${latest}"

    checkpoint_file=$(find "${directory}" -maxdepth 1 -type f \
        -name 'checkpoint-*.vls' -printf '%f\n' 2>/dev/null |
        sort | tail -1)
    [[ -z ${checkpoint_file} ]] ||
        printf 'checkpoint=%s\n' "${directory}/${checkpoint_file}"

    if [[ -f ${directory}/status ]]; then
        sed -n '/^exit_code=/p;/^sim_exit_code=/p;/^validation=/p;/^finished_utc=/p' \
            "${directory}/status"
    fi
    printf 'run_dir=%s\n' "${directory}"
}

command=${1:-}
if [[ ${command} == status ]]; then
    shift
    (($# <= 1)) || die 'usage: ./run/run.sh status [INSTANCE]'
    status_instance "${1:-latest}"
    exit 0
fi

# Preserve the existing command surface; only status needs the artifact-based
# implementation because it must not depend on host tmux visibility.
exec "${script_dir}/run" "$@"
