# Convert the host retirement/trap event stream into fixed-cycle PC samples.
# The most recently observed PC is held across cycles without a retire event,
# so stalls contribute time to the function in which they occur.

BEGIN {
    if (period <= 0) {
        print "host-pc-sampler.awk: period must be positive" > "/dev/stderr"
        exit 2
    }
    next_sample = 0
    have_pc = 0
    last_event_cycle = 0
    print "# cycle\tpc\tlast_event_cycle"
}

/^#/ {
    if (match($0, /start_cycle=[0-9]+/)) {
        start_cycle = substr($0, RSTART + 12, RLENGTH - 12) + 0
        next_sample = (int(start_cycle / period) + 1) * period
        print "# source_start_cycle=" start_cycle " period=" period
    }
    next
}

function field_value(prefix,    i) {
    for (i = 1; i <= NF; ++i) {
        if (index($i, prefix) == 1)
            return substr($i, length(prefix) + 1)
    }
    return ""
}

function emit_sample() {
    printf "%u\t%s\t%u\n", next_sample, last_pc, last_event_cycle
    fflush()
    next_sample += period
}

$1 == "RET" || $1 == "TRAP" {
    event_cycle = field_value("cycle=") + 0
    while (have_pc && next_sample != 0 && next_sample < event_cycle)
        emit_sample()

    if ($1 == "RET")
        event_pc = field_value("pc=")
    else
        event_pc = field_value("vector=")

    if (event_pc != "") {
        sub(/^0x/, "", event_pc)
        last_pc = tolower(event_pc)
        last_event_cycle = event_cycle
        have_pc = 1
    }
}

END {
    while (have_pc && next_sample != 0 && next_sample <= last_event_cycle)
        emit_sample()
    if (state_path != "") {
        print "next_sample=" next_sample > state_path
        print "last_pc=" last_pc >> state_path
        print "last_event_cycle=" last_event_cycle >> state_path
        close(state_path)
    }
}
