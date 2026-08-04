#!/bin/sh

mode=${1:---quick}
case "$mode" in
    --quick|--full) ;;
    *)
        echo "usage: openrv64-user-tests [--quick|--full]"
        exit 2
        ;;
esac

cpus=$(/usr/bin/nproc)
echo "OPENRV64_USER_TESTS_BEGIN mode=$mode cpus=$cpus"
if [ "$cpus" -lt 2 ]; then
    echo "OPENRV64_USER_TESTS_SKIP reason=requires_2_cpus"
    exit 77
fi

timeout_seconds=20
if [ "$mode" = "--full" ]; then
    timeout_seconds=300
fi

/usr/bin/timeout "$timeout_seconds" /bin/openrv64_user_stress "$mode"
raw_status=$?

if [ -x /bin/pthread_lock_stress ]; then
    /usr/bin/timeout "$timeout_seconds" /bin/pthread_lock_stress "$mode"
    pthread_status=$?
else
    echo "PTHREAD_LOCK_SKIP reason=no_rv64ima_pthread_binary"
    pthread_status=77
fi

if [ "$raw_status" -ne 0 ] && [ "$raw_status" -ne 77 ]; then
    echo "OPENRV64_USER_TESTS_FAIL raw_status=$raw_status pthread_status=$pthread_status"
    exit "$raw_status"
fi
if [ "$pthread_status" -ne 0 ] && [ "$pthread_status" -ne 77 ]; then
    echo "OPENRV64_USER_TESTS_FAIL raw_status=$raw_status pthread_status=$pthread_status"
    exit "$pthread_status"
fi

echo "OPENRV64_USER_TESTS_PASS raw_status=$raw_status pthread_status=$pthread_status"
exit 0
