"""Internal representation for openrv64-pipeline-state-v1 traces.

Numeric ABI: rtl/core/trace/tomasulo-trace-defs.v, documented in
doc/tomasulo_pipeline_trace.md.  This is a component-residency trace:
an instruction normally has a ROB row at the same time as a SCHED,
REGREAD, EXEC, COMPLETE, LSQ, or RETIRE row, so rows are folded per
component, not into one exclusive stage.

Row columns:
  schema, cycle, insn_id, core_id, pc, instr, stage, slot, lane, state,
  reason, blocker_id, flags, detail0, detail1
"""

SCHEMA = "openrv64-pipeline-state-v1"

# Sentinel "no uid" for per-cycle oldest-entry tracking.
NO_UID = 1 << 62

# Component codes (the CSV "stage" column).
FETCH, DECODE, SCHED, REGREAD, EXEC, COMPLETE, LSQ, ROB, RETIRE = range(1, 10)

STAGE_NAMES = {
    1: "FETCH", 2: "DECODE", 3: "SCHED", 4: "REGREAD", 5: "EXEC",
    6: "COMPLETE", 7: "LSQ", 8: "ROB", 9: "RETIRE",
}

STATE_NAMES = {
    1: "PRESENT", 2: "WAIT", 3: "READY", 4: "FIRE", 5: "PENDING",
    6: "ACTIVE", 7: "WORKER", 8: "LOAD", 9: "STORE",
    10: "INCOMPLETE", 11: "COMPLETE", 12: "HEAD",
}

# Component-local state codes used by the parser.
ST_PRESENT, ST_WAIT, ST_READY, ST_FIRE = 1, 2, 3, 4
ST_WORKER = 7
ST_LOAD, ST_STORE = 8, 9

REASON_NAMES = {
    0: "NONE", 1: "SRC1_PENDING", 2: "SRC2_PENDING",
    3: "BOTH_SOURCES_PENDING", 4: "OLDER_HARD", 5: "PERSISTENT_BARRIER",
    6: "RETIRE_HEAD_REQUIRED", 7: "OLDER_MEMORY", 8: "OLDER_CONTROL",
    9: "BRANCH_ORDER", 10: "PIPE_CONFLICT", 11: "ISSUE_WIDTH",
    12: "PIPE_BUSY", 13: "REGREAD_PORT", 14: "REGREAD_BUFFER",
    15: "EXEC_WORKER", 16: "COMPLETION_BACKPRESSURE",
    17: "XLATE_ARBITRATION", 18: "XLATE_RESPONSE", 19: "STORE_GUARD",
    20: "MEMORY_ORDER", 21: "MEMORY_PORT", 22: "MEMORY_RESPONSE",
    23: "POSTED_STORE_ACK", 24: "ROB_INCOMPLETE", 25: "ROB_ORDER",
    26: "RETIRE_BACKPRESSURE", 27: "REDIRECT_SQUASH",
    28: "FRONTEND_CONTROL", 29: "BP_STALL", 30: "TRANSLATION_BARRIER",
    31: "RENAME_TAG", 32: "ROB_CAPACITY", 33: "SCHED_CAPACITY",
    34: "DECODE_DOWNSTREAM", 35: "HALT_OR_WFI", 36: "RESULT_ARBITRATION",
    37: "ATOMIC_UNIT", 38: "BP_LOOKUP", 39: "BP_CAPACITY",
    40: "BP_TARGET", 41: "LOAD_CONFLICT_RECORD", 255: "UNKNOWN",
}

# Physical pipes for EXEC lane values; 255 (PIPE_NONE) = unassigned.
PIPE_NAMES = {0: "EX0", 1: "EX1", 2: "MEM0", 3: "MEM1", 255: "-"}
PIPE_NONE = 255

# ROB detail0 layout: registers plus control/class bits.
ROB_D0_RS1_SHIFT, ROB_D0_RS2_SHIFT, ROB_D0_RD_SHIFT = 0, 8, 16
ROB_D0_REG_WRITE, ROB_D0_USES_RS1, ROB_D0_USES_RS2 = 24, 25, 26
ROB_D0_HARD, ROB_D0_LOAD, ROB_D0_STORE = 27, 28, 29
ROB_D0_BRANCH, ROB_D0_JUMP, ROB_D0_PRED_TAKEN = 30, 31, 32


def stage_name(stage):
    return STAGE_NAMES.get(stage, "stage%d" % stage)


def state_name(state):
    return STATE_NAMES.get(state, "state%d" % state)


def reason_name(reason):
    return REASON_NAMES.get(reason, "reason%d" % reason)


def opcode_is_load(instr):
    op = instr & 0x7F
    return op == 0x03 or op == 0x07  # LOAD, LOAD-FP (no RVC in this trace)


def opcode_is_store(instr):
    op = instr & 0x7F
    return op == 0x23 or op == 0x27  # STORE, STORE-FP


class Insn(object):
    """Aggregated lifetime of one dynamic instruction (uid = insn_id).

    One-shot FIRE events keep exact cycles; per-cycle residency rows are
    folded into counters and per-reason histograms.  Unset cycle fields
    are None: the instruction never reached that component.
    """

    __slots__ = (
        "uid", "tag", "pc", "instr",
        "fetch_first_cycle", "fetch_lane", "fetch_cycles", "fetch_flags",
        "decode_cycle", "decode_wait_cycles", "decode_wait_reasons",
        "sched_slot", "sched_enter_cycle", "sched_ready_cycles",
        "sched_wait_cycles", "sched_wait_reasons", "sched_blocker",
        "regread_cycles",
        "issue_cycle", "issue_pipe", "exec_wait_cycles",
        "exec_worker_cycles",
        "complete_cycle", "complete_wait_cycles", "wb_value", "next_pc",
        "lsq_cycles", "lsq_is_store", "lsq_wait_reasons",
        "mem_vaddr", "mem_paddr",
        "rob_slot", "rob_cycles", "rob_info",
        "retire_cycle", "retire_wait_cycles",
    )

    def __init__(self, uid, tag, pc, instr):
        self.uid = uid
        self.tag = tag
        self.pc = pc
        self.instr = instr
        self.fetch_first_cycle = None
        self.fetch_lane = -1
        self.fetch_cycles = 0
        self.fetch_flags = 0
        self.decode_cycle = None
        self.decode_wait_cycles = 0
        self.decode_wait_reasons = None   # dict reason -> cycles, lazy
        self.sched_slot = -1
        self.sched_enter_cycle = None
        self.sched_ready_cycles = 0
        self.sched_wait_cycles = 0
        self.sched_wait_reasons = None    # dict reason -> cycles, lazy
        self.sched_blocker = 0
        self.regread_cycles = 0
        self.issue_cycle = None
        self.issue_pipe = -1
        self.exec_wait_cycles = 0
        self.exec_worker_cycles = 0
        self.complete_cycle = None
        self.complete_wait_cycles = 0
        self.wb_value = None
        self.next_pc = None
        self.lsq_cycles = 0
        self.lsq_is_store = False
        self.lsq_wait_reasons = None      # dict reason -> cycles, lazy
        self.mem_vaddr = None
        self.mem_paddr = None
        self.rob_slot = -1
        self.rob_cycles = 0
        self.rob_info = None              # ROB detail0: regs + class bits
        self.retire_cycle = None
        self.retire_wait_cycles = 0


    def pack(self):
        """Flat tuple for cheap cross-process transfer (slot order)."""
        return (self.uid, self.tag, self.pc, self.instr, self.fetch_first_cycle, self.fetch_lane, self.fetch_cycles, self.fetch_flags, self.decode_cycle, self.decode_wait_cycles, self.decode_wait_reasons, self.sched_slot, self.sched_enter_cycle, self.sched_ready_cycles, self.sched_wait_cycles, self.sched_wait_reasons, self.sched_blocker, self.regread_cycles, self.issue_cycle, self.issue_pipe, self.exec_wait_cycles, self.exec_worker_cycles, self.complete_cycle, self.complete_wait_cycles, self.wb_value, self.next_pc, self.lsq_cycles, self.lsq_is_store, self.lsq_wait_reasons, self.mem_vaddr, self.mem_paddr, self.rob_slot, self.rob_cycles, self.rob_info, self.retire_cycle, self.retire_wait_cycles)

    @staticmethod
    def unpack(t):
        r = object.__new__(Insn)
        (r.uid, r.tag, r.pc, r.instr, r.fetch_first_cycle, r.fetch_lane, r.fetch_cycles, r.fetch_flags, r.decode_cycle, r.decode_wait_cycles, r.decode_wait_reasons, r.sched_slot, r.sched_enter_cycle, r.sched_ready_cycles, r.sched_wait_cycles, r.sched_wait_reasons, r.sched_blocker, r.regread_cycles, r.issue_cycle, r.issue_pipe, r.exec_wait_cycles, r.exec_worker_cycles, r.complete_cycle, r.complete_wait_cycles, r.wb_value, r.next_pc, r.lsq_cycles, r.lsq_is_store, r.lsq_wait_reasons, r.mem_vaddr, r.mem_paddr, r.rob_slot, r.rob_cycles, r.rob_info, r.retire_cycle, r.retire_wait_cycles) = t
        return r

    @property
    def retired(self):
        return self.retire_cycle is not None

    @property
    def issued(self):
        return self.issue_cycle is not None

    @property
    def is_load(self):
        if self.rob_info is not None:
            return (self.rob_info >> ROB_D0_LOAD) & 1 == 1
        return opcode_is_load(self.instr)

    @property
    def is_store(self):
        if self.rob_info is not None:
            return (self.rob_info >> ROB_D0_STORE) & 1 == 1
        return opcode_is_store(self.instr)

    @property
    def is_branch(self):
        return (self.rob_info is not None
                and (self.rob_info >> ROB_D0_BRANCH) & 1 == 1)

    @property
    def is_jump(self):
        return (self.rob_info is not None
                and (self.rob_info >> ROB_D0_JUMP) & 1 == 1)

    @property
    def rd(self):
        if self.rob_info is None:
            return None
        return (self.rob_info >> ROB_D0_RD_SHIFT) & 31

    @property
    def rs1(self):
        if self.rob_info is None:
            return None
        return (self.rob_info >> ROB_D0_RS1_SHIFT) & 31

    @property
    def rs2(self):
        if self.rob_info is None:
            return None
        return (self.rob_info >> ROB_D0_RS2_SHIFT) & 31

    def __repr__(self):
        return "Insn(uid=%#x pc=%#x instr=%08x F=%s I=%s R=%s)" % (
            self.uid, self.pc, self.instr,
            self.fetch_first_cycle, self.issue_cycle, self.retire_cycle)


class Trace(object):
    """Parsed trace: per-uid Insn records plus trace-level aggregates."""

    def __init__(self, path=None):
        self.path = path
        self.schema = None
        self.rows = 0
        self.skipped_rows = 0
        self.parse_jobs = 1
        self.min_cycle = None
        self.max_cycle = None
        self.insns = {}            # uid -> Insn
        self.issue_counts = {}     # cycle -> EXEC FIREs that cycle
        self.retire_counts = {}    # cycle -> RETIRE FIREs that cycle
        # Per-cycle blocked-mode capture:
        # cycle -> [oldest WAITing sched uid, its reason, ready_seen]
        # (uid = _NO_UID when only READY entries were present)
        self.sched_cycles = {}
        # cycle -> [oldest live ROB uid, its state]; min uid = head
        self.rob_head_cycles = {}
        # cycles with a RETIRE WAIT row (retire backpressure observed)
        self.retire_backpressure_cycles = set()
        # cycle -> live entry counts (occupancy curves)
        self.rob_occ = {}
        self.rob_completed_occ = {}   # state COMPLETE (behind head) only
        self.sched_occ = {}
        # cycle -> decode-gate candidates present (frontend delivery)
        self.decode_cand = {}
        # (stage, state, reason) row counts, key packed as
        # stage << 14 | state << 9 | reason  (reason <= 255, state < 16)
        self.ssr_counts = {}

    @property
    def n_cycles(self):
        """Observed cycle span, inclusive."""
        if self.min_cycle is None:
            return 0
        return self.max_cycle - self.min_cycle + 1

    def width_histogram(self, counts, max_width=3):
        """Cycles with 0..max_width events over the observed span."""
        hist = [0] * (max_width + 1)
        for n in counts.values():
            hist[n if n <= max_width else max_width] += 1
        hist[0] += self.n_cycles - len(counts)
        return hist

    def issue_width_histogram(self, max_width=3):
        return self.width_histogram(self.issue_counts, max_width)

    def retire_width_histogram(self, max_width=3):
        return self.width_histogram(self.retire_counts, max_width)

    def ssr_table(self):
        """Decoded (stage, state, reason) -> count, sorted descending."""
        out = []
        for key, count in self.ssr_counts.items():
            out.append(((key >> 14, (key >> 9) & 31, key & 511), count))
        out.sort(key=lambda kv: -kv[1])
        return out
