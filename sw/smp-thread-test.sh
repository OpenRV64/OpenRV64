#!/bin/sh

cpus=$(/usr/bin/nproc)
if [ "$cpus" -lt 2 ]; then
    echo "SMP_THREADS_SKIP cpus=$cpus"
    exit 77
fi

echo "SMP_THREADS_BEGIN cpus=$cpus"
/usr/bin/timeout 5 /bin/smp_thread_probe
probe_status=$?
if [ "$probe_status" -ne 0 ]; then
    echo "SMP_THREADS_SCRIPT_FAIL probe_status=$probe_status"
    exit "$probe_status"
fi

if [ -x /bin/openrv64-user-tests ]; then
    /bin/openrv64-user-tests --quick
    suite_status=$?
else
    echo "OPENRV64_USER_TESTS_SKIP reason=binary_not_installed"
    suite_status=77
fi

if [ "$suite_status" -ne 0 ] && [ "$suite_status" -ne 77 ]; then
    echo "SMP_THREADS_SCRIPT_FAIL suite_status=$suite_status"
    exit "$suite_status"
fi

echo "SMP_THREADS_SCRIPT_PASS probe_status=$probe_status suite_status=$suite_status"
exit 0
