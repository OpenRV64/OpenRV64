/*
 * Short Linux userspace SMP/coherence/VM stress for OpenRV64.
 *
 * This binary is freestanding so it remains RV64IMA/lp64 and does not depend
 * on the target libc, TLS, or futex support.  Linux still owns scheduling,
 * mappings, TLB shootdowns, and page-table changes; the tests intentionally
 * cross those kernel/user and virtual/physical seams.
 */

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long u64;
typedef long s64;
typedef unsigned long usize;

#define MAX_HARTS 4U
#define STACK_BYTES 16384U
#define PAGE_BYTES 4096UL
#define CACHE_LINE_BYTES 64U

#define SYS_ftruncate 46
#define SYS_close 57
#define SYS_write 64
#define SYS_futex 98
#define SYS_exit_group 94
#define SYS_sched_setaffinity 122
#define SYS_sched_getaffinity 123
#define SYS_sched_yield 124
#define SYS_getcpu 168
#define SYS_munmap 215
#define SYS_mremap 216
#define SYS_mmap 222
#define SYS_mprotect 226
#define SYS_memfd_create 279

#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define MREMAP_MAYMOVE 1
#define MREMAP_FIXED 2
#define MFD_CLOEXEC 1
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_PRIVATE_FLAG 128

#define ENOSYS 38

#define CLONE_VM 0x00000100UL
#define CLONE_FS 0x00000200UL
#define CLONE_FILES 0x00000400UL
#define CLONE_SIGHAND 0x00000800UL
#define CLONE_THREAD 0x00010000UL
#define CLONE_SYSVSEM 0x00040000UL
#define CLONE_CHILD_CLEARTID 0x00200000UL
#define CLONE_CHILD_SETTID 0x01000000UL
#define WORKER_CLONE_FLAGS                                                   \
    (CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD |     \
     CLONE_SYSVSEM | CLONE_CHILD_CLEARTID | CLONE_CHILD_SETTID)

enum test_kind {
    TEST_NONE,
    TEST_AFFINITY,
    TEST_ATOMIC_ADD,
    TEST_CAS_TURN,
    TEST_TICKET_LOCK,
    TEST_DIFFERENT_LINES,
    TEST_DIFFERENT_PAGES,
    TEST_FALSE_SHARING,
    TEST_LINE_HANDOFF,
    TEST_ALIAS_ATOMIC,
    TEST_ALIAS_HANDOFF,
    TEST_VM_REMAP,
    TEST_FUTEX_MUTEX,
};

struct test_config {
    u32 atomic_iterations;
    u32 turn_iterations;
    u32 ticket_iterations;
    u32 line_iterations;
    u32 handoff_iterations;
    u32 alias_iterations;
    u32 vm_iterations;
    u32 futex_iterations;
};

struct line_value {
    u64 value;
    u8 padding[CACHE_LINE_BYTES - sizeof(u64)];
} __attribute__((aligned(CACHE_LINE_BYTES)));

struct page_value {
    u64 value;
    u8 padding[PAGE_BYTES - sizeof(u64)];
} __attribute__((aligned(PAGE_BYTES)));

struct alias_page {
    u64 counter;
    u32 token;
    u32 reserved;
    u64 payload;
};

extern s64 openrv64_clone_worker(u64 flags, void *child_stack_top,
                                 u64 worker_id, volatile u32 *child_tid);

static u8 worker_stacks[MAX_HARTS][STACK_BYTES] __attribute__((aligned(16)));
static volatile u32 worker_tid[MAX_HARTS];
static u32 cpu_ids[MAX_HARTS];
static volatile u32 observed_before[MAX_HARTS];
static volatile u32 observed_after[MAX_HARTS];
static volatile u64 worker_checksums[MAX_HARTS];

static volatile u32 active_test;
static volatile u32 active_workers;
static volatile u32 worker_cpu_offset;
static volatile u32 ready_count;
static volatile u32 done_count;
static volatile u32 start_gate;
static volatile u32 failure_count;
static volatile u32 suite_cpu_count;
static volatile u32 worker_iterations;

static volatile u64 shared_counter;
static volatile u64 cas_counter;
static volatile u64 ticket_next;
static volatile u64 ticket_owner;
static volatile u64 protected_counter;
static volatile u64 protected_checksum;
static struct line_value separate_lines[MAX_HARTS];
static struct page_value separate_pages[MAX_HARTS];
static volatile u64 false_sharing_slots[MAX_HARTS]
    __attribute__((aligned(CACHE_LINE_BYTES)));
static volatile u32 handoff_token __attribute__((aligned(CACHE_LINE_BYTES)));
static volatile u64 handoff_payload;

static struct alias_page *alias_a;
static struct alias_page *alias_b;

static volatile u32 vm_phase;
static volatile u32 vm_ack;
static volatile u32 vm_abort;
static volatile u32 vm_rounds;
static volatile u64 *vm_current;
static volatile u64 *vm_other;
static volatile u64 vm_old_value;
static volatile u64 vm_new_value;

static volatile u32 futex_mutex;
static volatile u32 futex_wait_calls;
static volatile u64 futex_counter;

static u32 tests_passed;
static u32 tests_failed;
static u32 tests_skipped;

static inline s64 syscall1(s64 nr, s64 x0)
{
    register s64 a0 __asm__("a0") = x0;
    register s64 a7 __asm__("a7") = nr;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
    return a0;
}

static inline s64 syscall2(s64 nr, s64 x0, s64 x1)
{
    register s64 a0 __asm__("a0") = x0;
    register s64 a1 __asm__("a1") = x1;
    register s64 a7 __asm__("a7") = nr;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
    return a0;
}

static inline s64 syscall3(s64 nr, s64 x0, s64 x1, s64 x2)
{
    register s64 a0 __asm__("a0") = x0;
    register s64 a1 __asm__("a1") = x1;
    register s64 a2 __asm__("a2") = x2;
    register s64 a7 __asm__("a7") = nr;
    __asm__ volatile("ecall" : "+r"(a0)
                     : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}

static inline s64 syscall5(s64 nr, s64 x0, s64 x1, s64 x2, s64 x3, s64 x4)
{
    register s64 a0 __asm__("a0") = x0;
    register s64 a1 __asm__("a1") = x1;
    register s64 a2 __asm__("a2") = x2;
    register s64 a3 __asm__("a3") = x3;
    register s64 a4 __asm__("a4") = x4;
    register s64 a7 __asm__("a7") = nr;
    __asm__ volatile("ecall" : "+r"(a0)
                     : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a7)
                     : "memory");
    return a0;
}

static inline s64 syscall6(s64 nr, s64 x0, s64 x1, s64 x2, s64 x3, s64 x4,
                           s64 x5)
{
    register s64 a0 __asm__("a0") = x0;
    register s64 a1 __asm__("a1") = x1;
    register s64 a2 __asm__("a2") = x2;
    register s64 a3 __asm__("a3") = x3;
    register s64 a4 __asm__("a4") = x4;
    register s64 a5 __asm__("a5") = x5;
    register s64 a7 __asm__("a7") = nr;
    __asm__ volatile("ecall" : "+r"(a0)
                     : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5),
                       "r"(a7)
                     : "memory");
    return a0;
}

static usize string_length(const char *text)
{
    usize length = 0;
    while (text[length] != '\0')
        length++;
    return length;
}

static int string_equal(const char *left, const char *right)
{
    usize index = 0;
    while (left[index] == right[index]) {
        if (left[index] == '\0')
            return 1;
        index++;
    }
    return 0;
}

static void write_text(const char *text)
{
    usize length = string_length(text);
    while (length != 0) {
        s64 written = syscall3(SYS_write, 1, (s64)text, (s64)length);
        if (written <= 0)
            return;
        text += written;
        length -= (usize)written;
    }
}

static void write_u64(u64 value)
{
    char buffer[24];
    usize cursor = sizeof(buffer);
    do {
        u64 quotient = value / 10;
        buffer[--cursor] = (char)('0' + (value - quotient * 10));
        value = quotient;
    } while (value != 0);
    (void)syscall3(SYS_write, 1, (s64)&buffer[cursor],
                   (s64)(sizeof(buffer) - cursor));
}

static void report_test(const char *name, const char *status, u64 iterations)
{
    write_text("OPENRV64_USER_TEST name=");
    write_text(name);
    write_text(" status=");
    write_text(status);
    write_text(" harts=");
    write_u64(suite_cpu_count);
    write_text(" iterations=");
    write_u64(iterations);
    write_text("\n");
}

static void pass_test(const char *name, u64 iterations)
{
    tests_passed++;
    report_test(name, "PASS", iterations);
}

static void fail_test(const char *name, u64 iterations)
{
    tests_failed++;
    report_test(name, "FAIL", iterations);
}

static void skip_test(const char *name)
{
    tests_skipped++;
    report_test(name, "SKIP", 0);
}

static inline void cpu_relax(void)
{
    __asm__ volatile("nop" ::: "memory");
}

static void wait_for_u32(volatile u32 *address, u32 value)
{
    u32 spins = 0;
    while (__atomic_load_n(address, __ATOMIC_ACQUIRE) != value) {
        cpu_relax();
        if ((++spins & 0x3fffU) == 0)
            (void)syscall1(SYS_sched_yield, 0);
    }
}

static int pin_to_cpu(u32 cpu)
{
    u64 mask = 1UL << cpu;
    return syscall3(SYS_sched_setaffinity, 0, sizeof(mask), (s64)&mask) < 0;
}

static int current_cpu(u32 *cpu)
{
    return syscall3(SYS_getcpu, (s64)cpu, 0, 0) < 0;
}

static u32 discover_cpus(void)
{
    u64 mask = 0;
    u32 count = 0;
    u32 bit;
    if (syscall3(SYS_sched_getaffinity, 0, sizeof(mask), (s64)&mask) < 0)
        return 0;
    for (bit = 0; bit < 64 && count < MAX_HARTS; bit++) {
        if ((mask & (1UL << bit)) != 0)
            cpu_ids[count++] = bit;
    }
    return count;
}

static void clear_worker_state(enum test_kind kind, u32 workers, u32 offset,
                               u32 iterations)
{
    u32 index;
    active_test = (u32)kind;
    active_workers = workers;
    worker_cpu_offset = offset;
    worker_iterations = iterations;
    ready_count = 0;
    done_count = 0;
    start_gate = 0;
    failure_count = 0;
    for (index = 0; index < MAX_HARTS; index++) {
        worker_tid[index] = 0;
        observed_before[index] = ~0U;
        observed_after[index] = ~0U;
        worker_checksums[index] = 0;
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

static int start_workers(enum test_kind kind, u32 workers, u32 offset,
                         u32 iterations)
{
    u32 index;
    clear_worker_state(kind, workers, offset, iterations);
    for (index = 0; index < workers; index++) {
        void *top = &worker_stacks[index][STACK_BYTES];
        s64 pid = openrv64_clone_worker(WORKER_CLONE_FLAGS, top, index,
                                        &worker_tid[index]);
        if (pid < 0) {
            write_text("OPENRV64_USER_SUITE_FAIL reason=clone\n");
            (void)syscall1(SYS_exit_group, 1);
            for (;;)
                cpu_relax();
        }
    }
    wait_for_u32(&ready_count, workers);
    __atomic_store_n(&start_gate, 1, __ATOMIC_RELEASE);
    return 0;
}

static int finish_workers(u32 workers)
{
    u32 index;
    wait_for_u32(&done_count, workers);
    for (index = 0; index < workers; index++)
        wait_for_u32(&worker_tid[index], 0);
    return __atomic_load_n(&failure_count, __ATOMIC_ACQUIRE) != 0;
}

static int run_workers(enum test_kind kind, u32 workers, u32 offset,
                       u32 iterations)
{
    if (start_workers(kind, workers, offset, iterations) != 0)
        return -1;
    return finish_workers(workers);
}

static void worker_failure(void)
{
    __atomic_fetch_add(&failure_count, 1, __ATOMIC_RELAXED);
}

static void worker_affinity(u32 id)
{
    u64 value = 0x9e3779b97f4a7c15UL ^ id;
    u32 index;
    for (index = 0; index < worker_iterations; index++) {
        value ^= value << 7;
        value ^= value >> 9;
        value += (u64)id + 1;
    }
    worker_checksums[id] = value;
}

static void worker_atomic_add(void)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++)
        __atomic_fetch_add(&shared_counter, 1, __ATOMIC_SEQ_CST);
}

static void worker_cas_turn(u32 id)
{
    u32 index;
    u32 workers = active_workers;
    for (index = 0; index < worker_iterations; index++) {
        u64 target = (u64)index * workers + id;
        for (;;) {
            u64 expected = target;
            if (__atomic_compare_exchange_n(&cas_counter, &expected,
                                            target + 1, 0,
                                            __ATOMIC_SEQ_CST,
                                            __ATOMIC_SEQ_CST))
                break;
            cpu_relax();
        }
    }
}

static void worker_ticket_lock(u32 id)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++) {
        u64 ticket = __atomic_fetch_add(&ticket_next, 1, __ATOMIC_RELAXED);
        while (__atomic_load_n(&ticket_owner, __ATOMIC_ACQUIRE) != ticket)
            cpu_relax();
        protected_counter++;
        protected_checksum ^= ((u64)id << 48) ^ ticket;
        __atomic_store_n(&ticket_owner, ticket + 1, __ATOMIC_RELEASE);
    }
}

static void worker_different_lines(u32 id)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++)
        __atomic_fetch_add(&separate_lines[id].value, 1, __ATOMIC_RELAXED);
}

static void worker_different_pages(u32 id)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++)
        __atomic_fetch_add(&separate_pages[id].value, 1, __ATOMIC_RELAXED);
}

static void worker_false_sharing(u32 id)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++)
        __atomic_fetch_add(&false_sharing_slots[id], 1, __ATOMIC_SEQ_CST);
}

static void do_handoff(volatile u32 *token, volatile u64 *payload, u32 id,
                       u32 workers, u32 iterations)
{
    u32 round;
    for (round = 0; round < iterations; round++) {
        u64 expected = (u64)round * workers + id;
        while (__atomic_load_n(token, __ATOMIC_ACQUIRE) != id)
            cpu_relax();
        if (__atomic_load_n(payload, __ATOMIC_RELAXED) != expected)
            worker_failure();
        __atomic_store_n(payload, expected + 1, __ATOMIC_RELAXED);
        __atomic_store_n(token, (id + 1) % workers, __ATOMIC_RELEASE);
    }
}

static void worker_line_handoff(u32 id)
{
    do_handoff(&handoff_token, &handoff_payload, id, active_workers,
               worker_iterations);
}

static void worker_alias_atomic(u32 id)
{
    struct alias_page *mapping = (id & 1U) ? alias_b : alias_a;
    u32 index;
    for (index = 0; index < worker_iterations; index++)
        __atomic_fetch_add(&mapping->counter, 1, __ATOMIC_SEQ_CST);
}

static void worker_alias_handoff(u32 id)
{
    struct alias_page *mapping = (id & 1U) ? alias_b : alias_a;
    do_handoff(&mapping->token, &mapping->payload, id, active_workers,
               worker_iterations);
}

static void worker_vm_remap(void)
{
    u32 round;
    for (round = 0; round < vm_rounds; round++) {
        u32 warm_phase = round * 2 + 1;
        u32 verify_phase = warm_phase + 1;
        volatile u64 *current;
        volatile u64 *other;
        u64 old_value;

        while (__atomic_load_n(&vm_phase, __ATOMIC_ACQUIRE) != warm_phase) {
            if (__atomic_load_n(&vm_abort, __ATOMIC_ACQUIRE))
                return;
            cpu_relax();
        }
        current = vm_current;
        old_value = vm_old_value;
        if (__atomic_load_n(current, __ATOMIC_RELAXED) != old_value)
            worker_failure();
        __atomic_store_n(current, old_value, __ATOMIC_RELAXED);
        __atomic_store_n(&vm_ack, warm_phase, __ATOMIC_RELEASE);

        while (__atomic_load_n(&vm_phase, __ATOMIC_ACQUIRE) != verify_phase) {
            if (__atomic_load_n(&vm_abort, __ATOMIC_ACQUIRE))
                return;
            cpu_relax();
        }
        current = vm_current;
        other = vm_other;
        if (__atomic_load_n(current, __ATOMIC_RELAXED) != vm_new_value)
            worker_failure();
        if (__atomic_load_n(other, __ATOMIC_RELAXED) != vm_old_value)
            worker_failure();
        __atomic_store_n(&vm_ack, verify_phase, __ATOMIC_RELEASE);
    }
}

static s64 futex_call(volatile u32 *address, u32 operation, u32 value)
{
    return syscall6(SYS_futex, (s64)address, operation, value, 0, 0, 0);
}

static void raw_futex_lock(void)
{
    u32 expected = 0;
    if (__atomic_compare_exchange_n(&futex_mutex, &expected, 1, 0,
                                    __ATOMIC_ACQUIRE,
                                    __ATOMIC_RELAXED))
        return;
    for (;;) {
        if (__atomic_exchange_n(&futex_mutex, 2, __ATOMIC_ACQUIRE) == 0)
            return;
        __atomic_fetch_add(&futex_wait_calls, 1, __ATOMIC_RELAXED);
        (void)futex_call(&futex_mutex, FUTEX_WAIT | FUTEX_PRIVATE_FLAG, 2);
    }
}

static void raw_futex_unlock(void)
{
    if (__atomic_fetch_sub(&futex_mutex, 1, __ATOMIC_RELEASE) != 1) {
        __atomic_store_n(&futex_mutex, 0, __ATOMIC_RELEASE);
        (void)futex_call(&futex_mutex, FUTEX_WAKE | FUTEX_PRIVATE_FLAG, 1);
    }
}

static void worker_futex_mutex(void)
{
    u32 index;
    for (index = 0; index < worker_iterations; index++) {
        u32 hold;
        raw_futex_lock();
        futex_counter++;
        for (hold = 0; hold < 8; hold++)
            cpu_relax();
        raw_futex_unlock();
    }
}

void openrv64_user_worker(u64 worker_id)
{
    u32 id = (u32)worker_id;
    u32 cpu_index = (id + worker_cpu_offset) % suite_cpu_count;
    u32 expected_cpu = cpu_ids[cpu_index];
    u32 cpu = ~0U;

    if (pin_to_cpu(expected_cpu) || current_cpu(&cpu) || cpu != expected_cpu)
        worker_failure();
    observed_before[id] = cpu;
    __atomic_fetch_add(&ready_count, 1, __ATOMIC_RELEASE);
    wait_for_u32(&start_gate, 1);

    switch ((enum test_kind)active_test) {
    case TEST_AFFINITY:
        worker_affinity(id);
        break;
    case TEST_ATOMIC_ADD:
        worker_atomic_add();
        break;
    case TEST_CAS_TURN:
        worker_cas_turn(id);
        break;
    case TEST_TICKET_LOCK:
        worker_ticket_lock(id);
        break;
    case TEST_DIFFERENT_LINES:
        worker_different_lines(id);
        break;
    case TEST_DIFFERENT_PAGES:
        worker_different_pages(id);
        break;
    case TEST_FALSE_SHARING:
        worker_false_sharing(id);
        break;
    case TEST_LINE_HANDOFF:
        worker_line_handoff(id);
        break;
    case TEST_ALIAS_ATOMIC:
        worker_alias_atomic(id);
        break;
    case TEST_ALIAS_HANDOFF:
        worker_alias_handoff(id);
        break;
    case TEST_VM_REMAP:
        worker_vm_remap();
        break;
    case TEST_FUTEX_MUTEX:
        worker_futex_mutex();
        break;
    default:
        worker_failure();
        break;
    }

    cpu = ~0U;
    if (current_cpu(&cpu) || cpu != expected_cpu)
        worker_failure();
    observed_after[id] = cpu;
    __atomic_fetch_add(&done_count, 1, __ATOMIC_RELEASE);
}

static int validate_affinity(u32 workers, u32 offset)
{
    u32 id;
    for (id = 0; id < workers; id++) {
        u32 expected = cpu_ids[(id + offset) % suite_cpu_count];
        if (observed_before[id] != expected || observed_after[id] != expected)
            return -1;
    }
    return 0;
}

static void test_affinity(const struct test_config *config)
{
    u32 id;
    int failed = run_workers(TEST_AFFINITY, suite_cpu_count, 0,
                             config->line_iterations);
    for (id = 0; id < suite_cpu_count; id++) {
        if (worker_checksums[id] == 0)
            failed = -1;
    }
    if (validate_affinity(suite_cpu_count, 0) != 0)
        failed = -1;
    if (failed)
        fail_test("affinity_overlap", config->line_iterations);
    else
        pass_test("affinity_overlap", config->line_iterations);
}

static void test_atomic_add(const struct test_config *config)
{
    u64 expected = (u64)suite_cpu_count * config->atomic_iterations;
    shared_counter = 0;
    if (run_workers(TEST_ATOMIC_ADD, suite_cpu_count, 0,
                    config->atomic_iterations) || shared_counter != expected)
        fail_test("atomic_fetch_add", expected);
    else
        pass_test("atomic_fetch_add", expected);
}

static void test_cas_turn(const struct test_config *config)
{
    u64 expected = (u64)suite_cpu_count * config->turn_iterations;
    cas_counter = 0;
    if (run_workers(TEST_CAS_TURN, suite_cpu_count, 0,
                    config->turn_iterations) || cas_counter != expected)
        fail_test("cas_turn_handoff", expected);
    else
        pass_test("cas_turn_handoff", expected);
}

static void test_ticket_lock(const struct test_config *config)
{
    u64 expected = (u64)suite_cpu_count * config->ticket_iterations;
    ticket_next = 0;
    ticket_owner = 0;
    protected_counter = 0;
    protected_checksum = 0;
    if (run_workers(TEST_TICKET_LOCK, suite_cpu_count, 0,
                    config->ticket_iterations) ||
        ticket_next != expected || ticket_owner != expected ||
        protected_counter != expected)
        fail_test("ticket_lock", expected);
    else
        pass_test("ticket_lock", expected);
}

static void test_cache_lines(const struct test_config *config)
{
    u32 id;
    int failed;
    for (id = 0; id < MAX_HARTS; id++) {
        separate_lines[id].value = 0;
        separate_pages[id].value = 0;
        false_sharing_slots[id] = 0;
    }
    failed = run_workers(TEST_DIFFERENT_LINES, suite_cpu_count, 0,
                         config->line_iterations);
    for (id = 0; id < suite_cpu_count; id++) {
        if (separate_lines[id].value != config->line_iterations)
            failed = -1;
    }
    if (failed)
        fail_test("same_page_different_lines", config->line_iterations);
    else
        pass_test("same_page_different_lines", config->line_iterations);

    failed = run_workers(TEST_DIFFERENT_PAGES, suite_cpu_count, 0,
                         config->line_iterations);
    for (id = 0; id < suite_cpu_count; id++) {
        if (separate_pages[id].value != config->line_iterations)
            failed = -1;
    }
    if (failed)
        fail_test("different_pages", config->line_iterations);
    else
        pass_test("different_pages", config->line_iterations);

    failed = run_workers(TEST_FALSE_SHARING, suite_cpu_count, 0,
                         config->line_iterations);
    for (id = 0; id < suite_cpu_count; id++) {
        if (false_sharing_slots[id] != config->line_iterations)
            failed = -1;
    }
    if (failed)
        fail_test("false_sharing", config->line_iterations);
    else
        pass_test("false_sharing", config->line_iterations);
}

static void test_line_handoff(const struct test_config *config)
{
    u64 expected = (u64)suite_cpu_count * config->handoff_iterations;
    handoff_token = 0;
    handoff_payload = 0;
    if (run_workers(TEST_LINE_HANDOFF, suite_cpu_count, 0,
                    config->handoff_iterations) ||
        handoff_payload != expected || handoff_token != 0)
        fail_test("same_line_handoff", expected);
    else
        pass_test("same_line_handoff", expected);
}

static int setup_aliases(void)
{
    static const char name[] = "openrv64-user-alias";
    s64 fd = syscall2(SYS_memfd_create, (s64)name, MFD_CLOEXEC);
    s64 first;
    s64 second;
    if (fd < 0)
        return -1;
    if (syscall2(SYS_ftruncate, fd, PAGE_BYTES) < 0) {
        (void)syscall1(SYS_close, fd);
        return -1;
    }
    first = syscall6(SYS_mmap, 0, PAGE_BYTES, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    second = syscall6(SYS_mmap, 0, PAGE_BYTES, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, 0);
    (void)syscall1(SYS_close, fd);
    if (first < 0 || second < 0) {
        if (first >= 0)
            (void)syscall2(SYS_munmap, first, PAGE_BYTES);
        if (second >= 0)
            (void)syscall2(SYS_munmap, second, PAGE_BYTES);
        return -1;
    }
    alias_a = (struct alias_page *)first;
    alias_b = (struct alias_page *)second;
    alias_a->counter = 0;
    alias_a->token = 0;
    alias_a->payload = 0;
    return 0;
}

static void teardown_aliases(void)
{
    if (alias_a != (void *)0)
        (void)syscall2(SYS_munmap, (s64)alias_a, PAGE_BYTES);
    if (alias_b != (void *)0)
        (void)syscall2(SYS_munmap, (s64)alias_b, PAGE_BYTES);
    alias_a = (void *)0;
    alias_b = (void *)0;
}

static void test_aliases(const struct test_config *config)
{
    u64 expected;
    int failed;
    if (setup_aliases() != 0) {
        fail_test("va_alias_setup", 0);
        teardown_aliases();
        return;
    }

    expected = (u64)suite_cpu_count * config->alias_iterations;
    failed = run_workers(TEST_ALIAS_ATOMIC, suite_cpu_count, 0,
                         config->alias_iterations);
    if (failed || alias_a->counter != expected || alias_b->counter != expected)
        fail_test("va_alias_atomic", expected);
    else
        pass_test("va_alias_atomic", expected);

    alias_a->token = 0;
    alias_a->payload = 0;
    expected = (u64)suite_cpu_count * config->handoff_iterations;
    failed = run_workers(TEST_ALIAS_HANDOFF, suite_cpu_count, 0,
                         config->handoff_iterations);
    if (failed || alias_a->payload != expected ||
        alias_b->payload != expected || alias_a->token != 0)
        fail_test("va_alias_handoff", expected);
    else
        pass_test("va_alias_handoff", expected);
    teardown_aliases();
}

static void test_vm_remap(const struct test_config *config)
{
    s64 mapping;
    volatile u64 *current;
    volatile u64 *other;
    u32 round;
    int failed = 0;

    mapping = syscall6(SYS_mmap, 0, PAGE_BYTES * 2,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping < 0) {
        fail_test("remote_mmap_remap", config->vm_iterations);
        return;
    }
    current = (volatile u64 *)mapping;
    other = (volatile u64 *)(mapping + PAGE_BYTES);
    *current = 0x1111000000000000UL;
    *other = 0x2222000000000000UL;
    vm_phase = 0;
    vm_ack = 0;
    vm_abort = 0;
    vm_rounds = config->vm_iterations;
    vm_current = current;
    vm_other = other;
    vm_old_value = *current;
    vm_new_value = 0;

    (void)start_workers(TEST_VM_REMAP, 1, 1, config->vm_iterations);

    for (round = 0; round < config->vm_iterations; round++) {
        volatile u64 *moved;
        s64 remapped;
        s64 replacement;
        u64 old_value = *current;
        u64 new_value = 0xa500000000000000UL | ((u64)round << 8) | 0x5a;
        u32 warm_phase = round * 2 + 1;
        u32 verify_phase = warm_phase + 1;

        vm_current = current;
        vm_other = other;
        vm_old_value = old_value;
        __atomic_store_n(&vm_phase, warm_phase, __ATOMIC_RELEASE);
        wait_for_u32(&vm_ack, warm_phase);

        if (syscall3(SYS_mprotect, (s64)current, PAGE_BYTES,
                     PROT_READ) < 0 ||
            syscall3(SYS_mprotect, (s64)current, PAGE_BYTES,
                     PROT_READ | PROT_WRITE) < 0) {
            failed = -1;
            break;
        }
        remapped = syscall5(SYS_mremap, (s64)current, PAGE_BYTES,
                            PAGE_BYTES, MREMAP_MAYMOVE | MREMAP_FIXED,
                            (s64)other);
        if (remapped != (s64)other) {
            failed = -1;
            break;
        }
        moved = (volatile u64 *)remapped;
        replacement = syscall6(SYS_mmap, (s64)current, PAGE_BYTES,
                               PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                               -1, 0);
        if (replacement != (s64)current) {
            failed = -1;
            break;
        }
        *current = new_value;
        vm_current = current;
        vm_other = moved;
        vm_old_value = old_value;
        vm_new_value = new_value;
        __atomic_store_n(&vm_phase, verify_phase, __ATOMIC_RELEASE);
        wait_for_u32(&vm_ack, verify_phase);

        other = current;
        current = moved;
    }

    if (failed)
        __atomic_store_n(&vm_abort, 1, __ATOMIC_RELEASE);
    if (finish_workers(1) != 0)
        failed = -1;

    /* Both virtual pages are mapped on successful completion. */
    (void)syscall2(SYS_munmap, mapping, PAGE_BYTES * 2);
    if (failed)
        fail_test("remote_mmap_remap", config->vm_iterations);
    else
        pass_test("remote_mmap_remap", config->vm_iterations);
}

static void test_futex_mutex(const struct test_config *config)
{
    volatile u32 probe = 0;
    s64 available = futex_call(&probe, FUTEX_WAKE | FUTEX_PRIVATE_FLAG, 1);
    u64 expected = (u64)suite_cpu_count * config->futex_iterations;
    if (available == -ENOSYS) {
        skip_test("futex_mutex");
        return;
    }
    if (available < 0) {
        fail_test("futex_mutex", expected);
        return;
    }
    futex_mutex = 1;
    futex_wait_calls = 0;
    futex_counter = 0;
    if (start_workers(TEST_FUTEX_MUTEX, suite_cpu_count, 0,
                      config->futex_iterations) != 0) {
        fail_test("futex_mutex", expected);
        return;
    }
    while (__atomic_load_n(&futex_wait_calls, __ATOMIC_ACQUIRE) <
           suite_cpu_count)
        (void)syscall1(SYS_sched_yield, 0);
    raw_futex_unlock();
    if (finish_workers(suite_cpu_count) || futex_counter != expected ||
        futex_wait_calls == 0)
        fail_test("futex_mutex", expected);
    else
        pass_test("futex_mutex", expected);
}

int openrv64_user_tests_main(s64 argc, char **argv)
{
    static const struct test_config quick = {
        128, 32, 32, 128, 16, 64, 4, 32,
    };
    static const struct test_config full = {
        20000, 2048, 4096, 20000, 1024, 10000, 128, 4096,
    };
    const struct test_config *config = &quick;
    int full_mode = 0;

    if (argc > 1 && string_equal(argv[1], "--full")) {
        config = &full;
        full_mode = 1;
    } else if (argc > 1 && !string_equal(argv[1], "--quick")) {
        write_text("usage: openrv64_user_stress [--quick|--full]\n");
        return 2;
    }

    suite_cpu_count = discover_cpus();
    write_text("OPENRV64_USER_SUITE_BEGIN mode=");
    write_text(full_mode ? "full" : "quick");
    write_text(" harts=");
    write_u64(suite_cpu_count);
    write_text("\n");
    if (suite_cpu_count < 2) {
        write_text("OPENRV64_USER_SUITE_SKIP reason=requires_2_cpus\n");
        return 77;
    }
    if (pin_to_cpu(cpu_ids[0])) {
        write_text("OPENRV64_USER_SUITE_FAIL reason=parent_affinity\n");
        return 1;
    }

    test_affinity(config);
    test_atomic_add(config);
    test_cas_turn(config);
    test_ticket_lock(config);
    test_cache_lines(config);
    test_line_handoff(config);
    test_aliases(config);
    test_vm_remap(config);
    test_futex_mutex(config);

    write_text("OPENRV64_USER_SUITE_END status=");
    write_text(tests_failed == 0 ? "PASS" : "FAIL");
    write_text(" passed=");
    write_u64(tests_passed);
    write_text(" failed=");
    write_u64(tests_failed);
    write_text(" skipped=");
    write_u64(tests_skipped);
    write_text("\n");
    return tests_failed == 0 ? 0 : 1;
}
