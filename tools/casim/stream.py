"""Frontend instruction stream: the input the backend model consumes.

Built from a parsed golden Trace (pipeviz).  Each SInsn is one dynamic
instruction in program order (uid order), carrying its class, register
dependences (reconstructed from ROB detail0 via a last-writer walk, the
same method as pipeviz src1_report), a frontend-availability cycle used to
anchor admission, and the golden issue/complete/retire cycles used only for
validation.

Class bits come from ROB detail0 when present (authoritative per the trace
doc); otherwise from the opcode.
"""

import os
import pickle
import sys

_TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

from pipeviz.model import (ROB_D0_LOAD, ROB_D0_STORE, ROB_D0_BRANCH,
                           ROB_D0_JUMP, ROB_D0_HARD, ROB_D0_REG_WRITE,
                           ROB_D0_USES_RS1, ROB_D0_USES_RS2,
                           ROB_D0_RS1_SHIFT, ROB_D0_RS2_SHIFT,
                           ROB_D0_RD_SHIFT)

# Instruction classes.
ALU, LOAD, STORE, BRANCH, JUMP, MULDIV, SYSTEM = range(7)
CLASS_NAMES = {ALU: "alu", LOAD: "load", STORE: "store", BRANCH: "branch",
               JUMP: "jump", MULDIV: "muldiv", SYSTEM: "system"}


class SInsn(object):
    __slots__ = (
        "uid", "pc", "instr", "klass",
        "rd", "rs1", "rs2", "uses_rs1", "uses_rs2", "reg_write",
        "is_hard", "persistent_hard", "is_jalr",
        "src1_uid", "src2_uid",
        "front_ready",           # frontend-available cycle (anchor)
        "exec_lat",              # golden issue->complete latency (for replay)
        "retired",
        # golden reference cycles (validation only)
        "g_issue", "g_complete", "g_retire", "g_pipe",
        # simulator outputs (filled by the model)
        "s_admit", "s_issue", "s_complete", "s_retire", "s_pipe",
        "s_squash",              # cycle a speculative entry was removed
        # speculative-stream identity (frontend model / synthesised work)
        "wrong_path",            # fetched down a path that never retires
        "squash_owner",          # uid of the control that discards it
        "squash_on",             # "predict" (frontend redirect) or "resolve"
        "resume_owner",          # uid of the redirect that opened its segment
        "segment",               # monotonic path-segment counter
        "fetch_cycle",           # cycle the candidate was presented
        "delivered",             # admitted at the backend gate
        "golden_uid",            # matching uid in the golden trace, if any
        "is_control",
    )

    def __init__(self, uid):
        self.uid = uid
        self.klass = None
        self.src1_uid = None
        self.src2_uid = None
        self.s_admit = None
        self.s_issue = None
        self.s_complete = None
        self.s_retire = None
        self.s_squash = None
        self.s_pipe = -1
        self.exec_lat = None
        self.g_issue = self.g_complete = self.g_retire = None
        self.g_pipe = -1
        self.wrong_path = False
        self.squash_owner = None
        self.squash_on = None
        self.resume_owner = 0
        self.segment = 0
        self.fetch_cycle = None
        self.delivered = False
        self.golden_uid = None
        self.is_control = False
        self.front_ready = None
        self.retired = True


def _opcode_class(instr, worker):
    op = instr & 0x7F
    if op in (0x03, 0x07):
        return LOAD
    if op in (0x23, 0x27):
        return STORE
    if op == 0x63:
        return BRANCH
    if op in (0x6F, 0x67):
        return JUMP
    if op == 0x73:
        return SYSTEM
    if worker:
        return MULDIV
    return ALU


def _classify(r):
    i = r.rob_info
    if i is None:
        return _opcode_class(r.instr, r.exec_worker_cycles)
    if (i >> ROB_D0_LOAD) & 1:
        return LOAD
    if (i >> ROB_D0_STORE) & 1:
        return STORE
    if (i >> ROB_D0_JUMP) & 1:
        return JUMP
    if (i >> ROB_D0_BRANCH) & 1:
        return BRANCH
    if r.exec_worker_cycles:
        return MULDIV
    # A hard op that is neither branch nor jump is a SYSTEM/fence/CSR barrier.
    if (i >> ROB_D0_HARD) & 1:
        return SYSTEM
    return ALU


def load_trace(csv_path, cache=True):
    """Parse (or load cached) a golden trace via pipeviz."""
    from pipeviz.parser import parse_file
    pkl = csv_path + ".pkl"
    if cache and os.path.exists(pkl) and \
            os.path.getmtime(pkl) >= os.path.getmtime(csv_path):
        with open(pkl, "rb") as f:
            return pickle.load(f)
    tr = parse_file(csv_path, jobs=8)
    if cache:
        try:
            with open(pkl, "wb") as f:
                pickle.dump(tr, f, protocol=4)
        except OSError:
            pass
    return tr


STREAM_MAGIC = "casim-frontend-stream-v1"


def write_stream(stream, path, source=None):
    """Dump a frontend stream so a backend run can consume it later.

    This is the handoff between the two decoupled runs: a frontend-only
    run produces the candidate sequence, wrong path included, and a
    backend-only run feeds that sequence at whatever rate it likes.
    Dependences are written out rather than recomputed, because the
    last-writer walk over a speculative stream needs the rename rollback
    at every redirect and cannot be redone from the instruction words
    alone.
    """
    with open(path, "w") as f:
        f.write("# %s\n" % STREAM_MAGIC)
        f.write("# source=%s insns=%d\n" % (source or "-", len(stream)))
        f.write("# uid pc instr klass rd rs1 rs2 bits deliver exec_lat "
                "src1 src2 squash_owner squash_on\n")
        for s in stream:
            bits = ((1 if s.uses_rs1 else 0) | (2 if s.uses_rs2 else 0)
                    | (4 if s.reg_write else 0) | (8 if s.is_hard else 0)
                    | (16 if s.persistent_hard else 0)
                    | (32 if s.is_jalr else 0) | (64 if s.is_control else 0)
                    | (128 if s.wrong_path else 0))
            f.write("%d %x %08x %d %d %d %d %d %s %s %s %s %s %s\n" % (
                s.uid, s.pc, s.instr, s.klass, s.rd, s.rs1, s.rs2, bits,
                "-" if s.front_ready is None else s.front_ready,
                "-" if s.exec_lat is None else s.exec_lat,
                "-" if s.src1_uid is None else s.src1_uid,
                "-" if s.src2_uid is None else s.src2_uid,
                "-" if s.squash_owner is None else s.squash_owner,
                s.squash_on or "-"))


def read_stream(path):
    def opt(v):
        return None if v == "-" else int(v)
    out = []
    with open(path) as f:
        if STREAM_MAGIC not in f.readline():
            raise ValueError("%s: not a %s file" % (path, STREAM_MAGIC))
        for line in f:
            if line.startswith("#"):
                continue
            p = line.split()
            if not p:
                continue
            s = SInsn(int(p[0]))
            s.pc = int(p[1], 16)
            s.instr = int(p[2], 16)
            s.klass = int(p[3])
            s.rd, s.rs1, s.rs2 = int(p[4]), int(p[5]), int(p[6])
            b = int(p[7])
            s.uses_rs1 = bool(b & 1)
            s.uses_rs2 = bool(b & 2)
            s.reg_write = bool(b & 4)
            s.is_hard = bool(b & 8)
            s.persistent_hard = bool(b & 16)
            s.is_jalr = bool(b & 32)
            s.is_control = bool(b & 64)
            s.wrong_path = bool(b & 128)
            s.retired = not s.wrong_path
            s.front_ready = opt(p[8])
            s.exec_lat = opt(p[9])
            s.src1_uid = opt(p[10])
            s.src2_uid = opt(p[11])
            s.squash_owner = opt(p[12])
            s.squash_on = None if p[13] == "-" else p[13]
            out.append(s)
    return out


def reset_sim(stream):
    """Clear model outputs so a stream can be rerun under a new config."""
    for s in stream:
        s.s_admit = s.s_issue = s.s_complete = None
        s.s_retire = s.s_squash = None
        s.s_pipe = -1


def build_stream(trace, retired_only=True, records=None):
    """Program-order list of SInsn with dependences reconstructed.

    retired_only=True yields the clean correct-path stream (matches the
    admission-anchored validation baseline).  With it False, every
    instruction that reached the scheduler is included (wrong-path work
    that consumed backend resources), in uid order.

    `records` overrides the selection with an explicit ordered list of
    trace records -- `btrace.architectural_chain` produces the one the
    frontend model replays, which differs from the retired set wherever
    an instruction leaves the ROB through a flush instead of a retire.
    """
    if records is not None:
        recs = list(records)
    else:
        recs = []
        for r in trace.insns.values():
            if retired_only:
                if not r.retired:
                    continue
            else:
                if r.sched_enter_cycle is None:
                    continue
            recs.append(r)
        recs.sort(key=lambda r: r.uid)

    last_writer = [None] * 32     # arch reg -> producing SInsn
    stream = []
    for r in recs:
        s = SInsn(r.uid)
        s.pc = r.pc
        s.instr = r.instr
        s.klass = _classify(r)
        info = r.rob_info
        if info is not None:
            s.rd = (info >> ROB_D0_RD_SHIFT) & 31
            s.rs1 = (info >> ROB_D0_RS1_SHIFT) & 31
            s.rs2 = (info >> ROB_D0_RS2_SHIFT) & 31
            s.uses_rs1 = bool((info >> ROB_D0_USES_RS1) & 1)
            s.uses_rs2 = bool((info >> ROB_D0_USES_RS2) & 1)
            s.reg_write = bool((info >> ROB_D0_REG_WRITE) & 1)
            s.is_hard = bool((info >> ROB_D0_HARD) & 1)
        else:
            s.rd = (r.instr >> 7) & 31
            s.rs1 = (r.instr >> 15) & 31
            s.rs2 = (r.instr >> 20) & 31
            s.uses_rs1 = s.uses_rs2 = True
            s.reg_write = s.rd != 0
            s.is_hard = s.klass == SYSTEM
        s.golden_uid = r.uid
        s.is_control = (r.instr & 0x7F) in (0x63, 0x67, 0x6F)
        s.is_jalr = (s.klass == JUMP) and ((r.instr & 0x7F) == 0x67)
        # Persistent barrier = hard, but conditional branches, direct JAL and
        # speculative JALR are handled by their own ordering, not head-gated.
        s.persistent_hard = s.is_hard and s.klass not in (BRANCH, JUMP)

        # Dependences: last older writer of each used source register.
        s.src1_uid = None
        s.src2_uid = None
        if s.uses_rs1 and s.rs1:
            p = last_writer[s.rs1]
            if p is not None:
                s.src1_uid = p.uid
        if s.uses_rs2 and s.rs2:
            p = last_writer[s.rs2]
            if p is not None:
                s.src2_uid = p.uid

        # Frontend anchor and golden reference cycles.
        s.front_ready = r.decode_cycle if r.decode_cycle is not None \
            else r.fetch_first_cycle
        s.retired = r.retired
        s.g_issue = r.issue_cycle
        s.g_complete = r.complete_cycle
        s.g_retire = r.retire_cycle
        s.g_pipe = r.issue_pipe
        if r.issue_cycle is not None and r.complete_cycle is not None:
            s.exec_lat = max(1, r.complete_cycle - r.issue_cycle)
        else:
            s.exec_lat = None

        stream.append(s)
        if s.reg_write and s.rd:
            last_writer[s.rd] = s

    return stream
