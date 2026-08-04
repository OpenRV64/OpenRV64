#define _GNU_SOURCE

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAX_THREADS 4

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_barrier_t start_barrier;
static uint64_t protected_counter;
static atomic_uint failures;
static int cpu_ids[MAX_THREADS];
static unsigned iterations;

static void write_text(const char *text)
{
    size_t length = 0;

    while (text[length] != '\0')
        length++;
    while (length != 0) {
        ssize_t written = write(STDOUT_FILENO, text, length);

        if (written <= 0)
            return;
        text += written;
        length -= (size_t)written;
    }
}

static void write_u64(uint64_t value)
{
    char digits[20];
    size_t count = 0;

    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value != 0);
    while (count != 0) {
        char digit = digits[--count];

        if (write(STDOUT_FILENO, &digit, 1) != 1)
            return;
    }
}

static void report_result(const char *status, unsigned thread_count,
                          uint64_t counter, uint64_t expected)
{
    write_text(status);
    write_text(" harts=");
    write_u64(thread_count);
    write_text(" iterations=");
    write_u64(iterations);
    write_text(" counter=");
    write_u64(counter);
    if (expected != counter) {
        write_text(" expected=");
        write_u64(expected);
    }
    write_text("\n");
}

static void *worker(void *opaque)
{
    unsigned id = (unsigned)(uintptr_t)opaque;
    cpu_set_t set;
    unsigned i;
    int barrier_status;

    CPU_ZERO(&set);
    CPU_SET(cpu_ids[id], &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    if (sched_getcpu() != cpu_ids[id])
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    barrier_status = pthread_barrier_wait(&start_barrier);
    if (barrier_status != 0 && barrier_status != PTHREAD_BARRIER_SERIAL_THREAD)
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);

    for (i = 0; i < iterations; i++) {
        if (pthread_mutex_lock(&lock) != 0) {
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
            return NULL;
        }
        protected_counter++;
        if (pthread_mutex_unlock(&lock) != 0) {
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
            return NULL;
        }
    }
    if (sched_getcpu() != cpu_ids[id])
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    return NULL;
}

int main(int argc, char **argv)
{
    cpu_set_t allowed;
    pthread_t threads[MAX_THREADS];
    unsigned thread_count = 0;
    unsigned cpu;
    unsigned i;
    uint64_t expected;

    iterations = (argc > 1 && strcmp(argv[1], "--full") == 0) ? 20000 : 128;
    if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
        write_text("PTHREAD_LOCK_FAIL reason=sched_getaffinity\n");
        return 1;
    }
    for (cpu = 0; cpu < CPU_SETSIZE && thread_count < MAX_THREADS; cpu++) {
        if (CPU_ISSET(cpu, &allowed))
            cpu_ids[thread_count++] = (int)cpu;
    }
    if (thread_count < 2) {
        write_text("PTHREAD_LOCK_SKIP reason=requires_2_cpus\n");
        return 77;
    }
    if (pthread_barrier_init(&start_barrier, NULL, thread_count) != 0) {
        write_text("PTHREAD_LOCK_FAIL reason=barrier_init\n");
        return 1;
    }
    for (i = 0; i < thread_count; i++) {
        if (pthread_create(&threads[i], NULL, worker, (void *)(uintptr_t)i) != 0) {
            write_text("PTHREAD_LOCK_FAIL reason=pthread_create\n");
            return 1;
        }
    }
    for (i = 0; i < thread_count; i++) {
        if (pthread_join(threads[i], NULL) != 0) {
            write_text("PTHREAD_LOCK_FAIL reason=pthread_join\n");
            return 1;
        }
    }
    expected = (uint64_t)thread_count * iterations;
    if (atomic_load_explicit(&failures, memory_order_acquire) != 0 ||
        protected_counter != expected) {
        report_result("PTHREAD_LOCK_FAIL", thread_count,
                      protected_counter, expected);
        return 1;
    }
    report_result("PTHREAD_LOCK_PASS", thread_count,
                  protected_counter, expected);
    return 0;
}
