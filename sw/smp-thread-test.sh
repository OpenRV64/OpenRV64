#!/bin/sh

cpus=$(/usr/bin/nproc)
if [ "$cpus" -lt 2 ]; then
    echo "SMP_THREADS_SKIP cpus=$cpus"
    exit 77
fi

echo "SMP_THREADS_BEGIN cpus=$cpus"
/usr/bin/timeout 5 /bin/smp_thread_probe
status=$?
if [ "$status" -eq 0 ]; then
    echo "SMP_THREADS_SCRIPT_PASS"
    exit 0
fi

echo "SMP_THREADS_SCRIPT_FAIL status=$status"
exit "$status"
