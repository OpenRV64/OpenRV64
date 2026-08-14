#!/usr/bin/env bash

# Shared, target-neutral run-directory and control helpers. Backends own how a
# workload is built and executed; this file owns the durable run contract.

openrv64_run_die() {
    printf 'run/run: %s\n' "$*" >&2
    exit 2
}

openrv64_run_shell_join() {
    local output= quoted argument
    for argument in "$@"; do
        printf -v quoted '%q' "${argument}"
        [[ -z ${output} ]] || output+=' '
        output+=${quoted}
    done
    printf '%s' "${output}"
}

openrv64_run_slugify() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-' |
        sed 's/^-*//; s/-*$//'
}

openrv64_run_resolve() {
    local log_root=$1
    local requested=${2:-latest}
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

    [[ -n ${candidate} ]] ||
        openrv64_run_die "run instance not found: ${requested}"
    case "${candidate}/" in
        "${log_root}/"*/) ;;
        *) openrv64_run_die \
            "run instance is outside ${log_root}: ${candidate}" ;;
    esac
    [[ -f ${candidate}/manager.env ]] ||
        openrv64_run_die "run instance lacks manager.env: ${candidate}"
    printf '%s' "${candidate}"
}

openrv64_run_load_manager() {
    local directory=$1
    unset run_id run_dir run_target backend tmux_session recorded_command
    unset harts threads timeout_seconds task_name
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    run_id=${run_id:-${directory##*/}}
    run_dir=${run_dir:-${directory}}
    # Compatibility with Linux runs created before the common contract.
    run_target=${run_target:-linux-smp}
    backend=${backend:-tools/run-linux-smp.sh}
    tmux_session=${tmux_session:-}
    recorded_command=${recorded_command:-}
}

openrv64_run_with_timeout() {
    local timeout_seconds=$1
    local directory=$2
    local task=$3
    shift 3

    [[ ${timeout_seconds} =~ ^[0-9]+$ ]] ||
        openrv64_run_die 'timeout must be a nonnegative number of seconds'
    if ((timeout_seconds == 0)); then
        exec "$@"
    fi
    command -v timeout >/dev/null 2>&1 ||
        openrv64_run_die 'GNU timeout is required for managed jobs'

    local started_epoch result elapsed status_file temporary_status
    local restore_errexit=0
    [[ $- != *e* ]] || restore_errexit=1
    started_epoch=$(date -u +%s)
    set +e
    timeout --signal=TERM --kill-after=60s "${timeout_seconds}s" "$@"
    result=$?
    ((restore_errexit == 0)) || set -e
    elapsed=$(($(date -u +%s) - started_epoch))

    # A command may itself return 124 or 137.  Only classify those results as
    # a managed timeout after the configured wall-clock interval elapsed.
    if ((elapsed >= timeout_seconds)) &&
       ((result == 124 || result == 137)); then
        status_file=${directory}/status
        temporary_status=${directory}/status.timeout.$$
        if [[ -f ${status_file} ]]; then
            awk '!/^(exit_code|validation|finished_utc|timed_out|timeout_seconds)=/' \
                "${status_file}" >"${temporary_status}"
        else
            {
                printf 'run_id=%s\n' "${directory##*/}"
                printf 'phase=unknown\n'
                printf 'sim_exit_code=\n'
            } >"${temporary_status}"
        fi
        {
            printf 'exit_code=124\n'
            printf 'validation=timeout\n'
            printf 'timed_out=1\n'
            printf 'timeout_seconds=%s\n' "${timeout_seconds}"
            printf 'finished_utc=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } >>"${temporary_status}"
        mv "${temporary_status}" "${status_file}"
        openrv64_run_notify \
            "${directory##*/} timed out after ${timeout_seconds}s; ${directory}" \
            "${task}"
    fi
    return "${result}"
}

openrv64_run_is_active() {
    local directory=$1
    local session=${2:-}
    if [[ -n ${session} ]] && tmux has-session -t "=${session}" 2>/dev/null; then
        return 0
    fi
    [[ -n $(find "${directory}/heartbeat" -mmin -2 -print 2>/dev/null) ]]
}

openrv64_run_status() {
    local log_root=$1
    local directory
    directory=$(openrv64_run_resolve "${log_root}" "${2:-latest}")
    openrv64_run_load_manager "${directory}"

    local now state phase activity_file activity_age heartbeat_age latest
    local checkpoint_file
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
        if openrv64_run_is_active "${directory}" "${tmux_session}"; then
            state=active
        elif [[ -n ${activity_age} && ${activity_age} -le 900 ]]; then
            state=active
        elif [[ -n ${activity_file} ]]; then
            state=stale
        fi
    fi

    printf 'run_id=%s\n' "${run_id}"
    printf 'target=%s\n' "${run_target}"
    printf 'backend=%s\n' "${backend}"
    printf 'state=%s\n' "${state}"
    printf 'phase=%s\n' "${phase}"
    [[ -z ${harts:-} ]] || printf 'harts=%s\n' "${harts}"
    [[ -z ${threads:-} ]] || printf 'threads=%s\n' "${threads}"
    [[ -z ${timeout_seconds:-} ]] ||
        printf 'timeout_seconds=%s\n' "${timeout_seconds}"
    [[ -z ${heartbeat_age} ]] ||
        printf 'heartbeat_age_seconds=%s\n' "${heartbeat_age}"
    [[ -z ${activity_age} ]] ||
        printf 'activity_age_seconds=%s\n' "${activity_age}"

    latest=$(rg 'OPENSBI_4H_PROGRESS|LINUX_SMP_ONLINE|CHECKPOINT SAVED|linux_panic=1|Kernel panic|openrv64#|PASS:|PERF_|%Fatal:|Assertion failed' \
        "${directory}/run.log" 2>/dev/null | tail -1 || true)
    [[ -z ${latest} ]] || printf 'latest=%s\n' "${latest}"

    checkpoint_file=$(find "${directory}" -maxdepth 1 -type f \
        \( -name 'checkpoint-*.vls' -o -name resume.vls \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr |
        sed -n '1s/^[^ ]* //p')
    [[ -z ${checkpoint_file} ]] || printf 'checkpoint=%s\n' "${checkpoint_file}"
    [[ ! -f ${directory}/status ]] || sed -n \
        '/^exit_code=/p;/^sim_exit_code=/p;/^validation=/p;/^timed_out=/p;/^finished_utc=/p' \
        "${directory}/status"
    printf 'run_dir=%s\n' "${directory}"
}

openrv64_run_list() {
    local log_root=$1
    local env_file directory state
    while IFS= read -r env_file; do
        directory=${env_file%/manager.env}
        openrv64_run_load_manager "${directory}"
        state=lost
        if [[ -f ${directory}/status ]]; then
            state=finished
        elif openrv64_run_is_active "${directory}" "${tmux_session}"; then
            state=active
        fi
        printf '%-58s %-9s target=%s\n' "${run_id}" "${state}" \
            "${run_target}" 2>/dev/null || return 0
    done < <(find "${log_root}" -mindepth 2 -maxdepth 2 \
        -name manager.env -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | sed 's/^[^ ]* //')
}

openrv64_run_log() {
    local log_root=$1
    local directory lines
    directory=$(openrv64_run_resolve "${log_root}" "${2:-latest}")
    lines=${3:-80}
    [[ ${lines} =~ ^[1-9][0-9]*$ ]] ||
        openrv64_run_die 'LINES must be positive'
    if [[ -f ${directory}/run.log ]]; then
        tail -n "${lines}" "${directory}/run.log"
    elif [[ -f ${directory}/build.log ]]; then
        tail -n "${lines}" "${directory}/build.log"
    else
        openrv64_run_die "run has no log yet: ${directory}"
    fi
}

openrv64_run_tail() {
    local log_root=$1
    local directory lines
    directory=$(openrv64_run_resolve "${log_root}" "${2:-latest}")
    lines=${3:-80}
    [[ ${lines} =~ ^[1-9][0-9]*$ ]] ||
        openrv64_run_die 'LINES must be positive'
    if [[ -f ${directory}/build.log ]]; then
        exec tail --retry -n "${lines}" -F \
            "${directory}/build.log" "${directory}/run.log"
    fi
    exec tail --retry -n "${lines}" -F "${directory}/run.log"
}

openrv64_run_attach() {
    local log_root=$1
    local directory
    directory=$(openrv64_run_resolve "${log_root}" "${2:-latest}")
    openrv64_run_load_manager "${directory}"
    [[ -n ${tmux_session} ]] ||
        openrv64_run_die "run has no tmux session: ${run_id}"
    tmux has-session -t "=${tmux_session}" 2>/dev/null ||
        openrv64_run_die "run is not active: ${run_id}"
    if [[ -n ${TMUX:-} ]]; then
        exec tmux switch-client -t "=${tmux_session}"
    fi
    exec tmux attach-session -t "=${tmux_session}"
}

openrv64_run_path() {
    openrv64_run_resolve "$1" "${2:-latest}"
    printf '\n'
}

openrv64_run_checkpoint() {
    local directory checkpoint found=0
    directory=$(openrv64_run_resolve "$1" "${2:-latest}")
    while IFS= read -r checkpoint; do
        found=1
        printf '%s %s bytes\n' "${checkpoint}" "$(stat -c %s "${checkpoint}")"
    done < <(find "${directory}" -maxdepth 1 -type f \
        \( -name 'checkpoint-*.vls' -o -name resume.vls \) -print | sort)
    ((found == 1)) || openrv64_run_die "no checkpoint found: ${directory}"
}

openrv64_run_command() {
    local directory
    directory=$(openrv64_run_resolve "$1" "${2:-latest}")
    openrv64_run_load_manager "${directory}"
    printf 'launch=%s\n' "${recorded_command}"
    sed -n '/^build_command=/p;/^command=/p;/^run_command=/p' \
        "${directory}/build.log" "${directory}/run.log" 2>/dev/null || true
}

openrv64_run_wait() {
    local log_root=$1
    local directory
    directory=$(openrv64_run_resolve "${log_root}" "${2:-latest}")
    openrv64_run_load_manager "${directory}"
    while [[ ! -f ${directory}/status ]] &&
          openrv64_run_is_active "${directory}" "${tmux_session}"; do
        sleep 5
    done
    openrv64_run_status "${log_root}" "${directory}"
}

openrv64_run_stop() {
    local directory
    directory=$(openrv64_run_resolve "$1" "${2:-latest}")
    openrv64_run_load_manager "${directory}"
    [[ -n ${tmux_session} ]] ||
        openrv64_run_die "run has no tmux session: ${run_id}"
    tmux has-session -t "=${tmux_session}" 2>/dev/null ||
        openrv64_run_die "run is not active: ${run_id}"
    tmux send-keys -t "${tmux_session}:" C-c
    printf 'stop_requested=%s\n' "${run_id}"
}

openrv64_run_notify() {
    local message=$1
    local task=$2
    local sendify=${OPENRV64_SENDIFY:-/home/bill/bin/sendify.py}
    [[ -x ${sendify} ]] || return 0
    "${sendify}" "${message}" "${task}" >/dev/null 2>&1 || true
}

openrv64_run_heartbeat_loop() {
    local heartbeat=$1
    while :; do
        touch "${heartbeat}"
        sleep 10
    done
}

openrv64_run_record_repository() {
    local directory=$1
    git rev-parse HEAD >"${directory}/git-head.txt"
    git status --short >"${directory}/git-status.txt"
    git diff --binary HEAD >"${directory}/worktree.patch"
}

openrv64_run_write_hashes() {
    local manifest=$1
    local output=$2
    local path
    : >"${output}"
    while IFS= read -r path; do
        [[ -n ${path} && ${path} != OPENRV64_RUN_INPUTS_V1 ]] || continue
        if [[ -f ${path} ]]; then
            sha256sum -- "${path}" >>"${output}"
        else
            printf 'MISSING  %s\n' "${path}" >>"${output}"
        fi
    done <"${manifest}"
}
