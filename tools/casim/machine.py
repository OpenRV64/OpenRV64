"""Per-cycle backend model.

Drives a frontend stream (stream.SInsn list, program order) through the
scheduler, execution pipes, ROB and in-order retirement, recording each
instruction's issue / complete / retire cycle.  Cycle numbers are recorded
to match the golden trace's convention directly: s_issue is the EXEC-FIRE
cycle, s_complete the COMPLETE-FIRE cycle, s_retire the RETIRE-FIRE cycle.

The model is deterministic and single-pass over cycles.  Within a cycle the
evaluation order mirrors the hardware's combinational settle: land
completions, retire from the head, admit from the frontend, then wake /
select / issue.

A stream that carries speculation -- one produced by `frontend.Frontend`,
or a golden's `--all-insns` stream -- also carries, per shadow
instruction, the control transfer that discards it.  Those instructions
hold scheduler entries, ROB entries and rename tags until that control
redirects, and are then removed together.  That is the point of feeding
wrong-path work to the backend: the pressure speculation really applies
is otherwise invisible, and on the bp8 golden it is about a third of
everything the scheduler ever holds.
"""

from .stream import (ALU, LOAD, STORE, BRANCH, JUMP, MULDIV, SYSTEM)

_EX0, _EX1, _MEM0, _MEM1 = 0, 1, 2, 3

# Why admission lost a slot, and why a resident entry did not issue.  The
# names match the trace's own reason codes so a model run and a pipeviz
# report of the same workload can be read side by side.
ADMIT_REASONS = ("delivered", "stream empty", "frontend delivery",
                 "SCHED_CAPACITY", "ROB_CAPACITY", "RENAME_TAG",
                 "decode width")
ISSUE_REASONS = ("sources pending", "PERSISTENT_BARRIER",
                 "RETIRE_HEAD_REQUIRED", "BRANCH_ORDER", "OLDER_MEMORY",
                 "OLDER_CONTROL", "PIPE_CONFLICT", "ISSUE_WIDTH")


def _pipes_for(klass):
    if klass == ALU:
        return (_EX0, _EX1)         # flexible
    if klass in (MULDIV,):
        return (_EX0,)              # M / Zbb worker lives on EX0
    if klass in (BRANCH, JUMP, SYSTEM):
        return (_EX1,)              # branch / CSR / system / fence / jump
    if klass == LOAD:
        return (_MEM0,)
    if klass == STORE:
        return (_MEM1,)
    return (_EX1,)


class _Entry(object):
    __slots__ = ("idx", "s", "ready_cycle", "issued")

    def __init__(self, idx, s, ready_cycle):
        self.idx = idx
        self.s = s
        self.ready_cycle = ready_cycle    # earliest issue cycle (admit+1)
        self.issued = False


class Machine(object):
    def __init__(self, cfg, stream, use_golden_latency=False):
        self.cfg = cfg
        self.stream = stream
        self.by_uid = {s.uid: s for s in stream}
        self.use_golden_latency = use_golden_latency
        self.stats = {}

    def _lat(self, s):
        if self.use_golden_latency and s.exec_lat is not None:
            return s.exec_lat
        c = self.cfg
        k = s.klass
        if k == LOAD:
            # Data memory is not modelled here (the cache hierarchy is out of
            # scope for the core model).  In mem-replay mode inject the real
            # per-access latency captured from the golden; otherwise magic.
            if c.mem_replay and s.exec_lat is not None:
                return s.exec_lat
            return c.lat_load
        if k == STORE:
            return c.lat_store
        if k == BRANCH:
            return c.lat_branch
        if k == JUMP:
            return c.lat_jump
        if k == MULDIV:
            # Multicycle worker latency is real execution time: replay it.
            return s.exec_lat if s.exec_lat is not None else 4
        return c.lat_alu

    def _src_ready(self, s, cycle):
        d = self.cfg.wakeup_delay
        for u in (s.src1_uid, s.src2_uid):
            if u is None:
                continue
            p = self.by_uid.get(u)
            if p is None or p.s_complete is None:
                return False
            if p.s_complete + d > cycle:
                return False
        return True

    def _squash_groups(self):
        """Shadow instructions, grouped by the control that discards them.

        `frontend_timed` holds the owners whose redirect is raised at the
        prediction -- one cycle after the transfer is admitted -- rather
        than when it resolves.  A correctly predicted taken branch is in
        that set: its shadow is the one or two sequential candidates
        fetched behind it, and they leave without waiting for execution.
        """
        members = {}
        frontend_timed = set()
        for i, s in enumerate(self.stream):
            if not s.wrong_path or s.squash_owner is None:
                continue
            members.setdefault(s.squash_owner, []).append(i)
            if s.squash_on == "predict":
                frontend_timed.add(s.squash_owner)
        return members, frontend_timed

    def run(self, max_cycles=2_000_000):
        cfg = self.cfg
        stream = self.stream
        n = len(stream)

        # Frontend availability: real anchor, or full-speed injection.
        if cfg.ideal_frontend:
            front = [0] * n
        else:
            front = [s.front_ready if s.front_ready is not None else 0
                     for s in stream]

        sched_cap = cfg.eff_sched_depth()
        rob_cap = cfg.eff_rob_depth()
        free_tags = (1 << 30) if cfg.ideal_prf else max(1, cfg.phys_regs + 1 - 32)

        speculative = any(s.wrong_path for s in stream)
        do_squash = cfg.squash_wrong_path and speculative
        if do_squash:
            squash_members, squash_frontend = self._squash_groups()
        else:
            squash_members, squash_frontend = {}, set()
        pending_squash = []     # [(owner uid, cycle its shadow leaves)]

        resident = []          # list[_Entry] currently in the scheduler
        rob = []               # list[SInsn] program-order, not yet retired
        rob_head = 0           # index into `rob` of the current head
        admit_ptr = 0          # next stream index to admit
        tags_used = 0

        issue_hist = [0] * (max(cfg.issue_width, 3) + 1)
        retire_hist = [0] * (max(cfg.retire_width, 3) + 1)
        admit_hist = [0] * (cfg.decode_width + 1)
        pipe_busy_cycles = [0, 0, 0, 0]     # EX0 EX1 MEM0 MEM1
        admit_stall = dict.fromkeys(ADMIT_REASONS, 0)
        issue_block = dict.fromkeys(ISSUE_REASONS, 0)
        sched_occ_sum = 0
        rob_occ_sum = 0
        sched_spec_sum = 0
        rob_spec_sum = 0
        cyc = 0
        retired_n = 0
        squashed_n = 0
        done_n = 0

        while done_n < n and cyc < max_cycles:
            cyc += 1

            # (0) Remove shadow work whose control has redirected.  Entries
            # are freed here rather than when they reach the head: the
            # squash is what gives the scheduler and ROB their capacity
            # back, and charging it later would hide the recovery.
            if pending_squash:
                keep = []
                work = []
                for owner, when in pending_squash:
                    if when <= cyc:
                        work.append(owner)
                    else:
                        keep.append((owner, when))
                pending_squash = keep
                gone = set()
                while work:
                    owner = work.pop()
                    for i in squash_members.get(owner, ()):
                        s = stream[i]
                        if s.s_squash is not None:
                            continue
                        s.s_squash = cyc
                        squashed_n += 1
                        done_n += 1
                        if s.s_admit is not None:
                            gone.add(s.uid)
                            if s.reg_write and s.rd:
                                tags_used -= 1
                        # A control on the discarded path takes its own
                        # shadow with it.
                        if s.uid in squash_members:
                            work.append(s.uid)
                if gone:
                    resident = [e for e in resident if e.s.uid not in gone]
                    rob = rob[:rob_head] + [x for x in rob[rob_head:]
                                            if x.uid not in gone]

            # (1) Retire in order from the ROB head, up to retire_width.
            rw = 0
            while rob_head < len(rob) and rw < cfg.retire_width:
                h = rob[rob_head]
                if h.s_complete is None or h.s_complete + 1 > cyc:
                    break
                if do_squash and h.wrong_path:
                    # Retirement stops dead at shadow work.  A wrong-path
                    # entry can complete and reach the head a cycle before
                    # its redirect lands; the head waits for the squash to
                    # remove it rather than committing it.
                    break
                # Store launch/ordering: a store retires from the head; its
                # completion is already gated to head by issue eligibility.
                h.s_retire = cyc
                if h.reg_write and h.rd:
                    tags_used -= 1
                rob_head += 1
                rw += 1
                retired_n += 1
                done_n += 1
            retire_hist[rw] += 1

            # (2) Admit from the frontend, up to decode_width.
            aw = 0
            stall = None
            while admit_ptr < n:
                s = stream[admit_ptr]
                if s.s_squash is not None:
                    # Already discarded by a redirect that resolved before
                    # this candidate reached the gate: it never arrives.
                    admit_ptr += 1
                    continue
                if aw >= cfg.decode_width:
                    stall = "decode width"
                    break
                if len(resident) >= sched_cap:
                    stall = "SCHED_CAPACITY"
                    break
                if (len(rob) - rob_head) >= rob_cap:
                    stall = "ROB_CAPACITY"
                    break
                if front[admit_ptr] > cyc:
                    stall = "frontend delivery"
                    break
                need_tag = s.reg_write and s.rd
                if need_tag and tags_used >= free_tags:
                    stall = "RENAME_TAG"
                    break
                s.s_admit = cyc
                resident.append(_Entry(admit_ptr, s, cyc + 1))
                rob.append(s)
                if need_tag:
                    tags_used += 1
                if do_squash and s.uid in squash_frontend:
                    pending_squash.append(
                        (s.uid, cyc + cfg.taken_redirect_delay
                         + cfg.squash_delay))
                admit_ptr += 1
                aw += 1
            if stall is None:
                stall = "stream empty"
            # Charge unused admission slots to whatever closed the gate.
            # Slots, not cycles: a cycle that admitted two of three and
            # then hit a full scheduler lost one slot to it, and counting
            # only fully-blocked cycles would miss that.
            lost = cfg.decode_width - aw
            if lost > 0:
                admit_stall[stall] += lost
            admit_stall["delivered"] += aw
            admit_hist[aw] += 1

            # (3) Wake / select / issue.
            # Oldest-unissued markers for ordering gates.
            oldest_persist = None    # smallest idx of unissued persistent-hard
            oldest_mem = None        # smallest idx of unissued memory op
            oldest_store = None      # smallest idx of unissued store
            oldest_branch = None     # smallest idx of unissued branch
            for e in resident:
                if e.issued:
                    continue
                s = e.s
                i = e.idx
                if s.persistent_hard and (oldest_persist is None or i < oldest_persist):
                    oldest_persist = i
                if s.klass in (LOAD, STORE):
                    if oldest_mem is None or i < oldest_mem:
                        oldest_mem = i
                if s.klass == STORE and (oldest_store is None or i < oldest_store):
                    oldest_store = i
                if s.klass == BRANCH and (oldest_branch is None or i < oldest_branch):
                    oldest_branch = i

            head_uid = rob[rob_head].uid if rob_head < len(rob) else None

            if resident:
                sched_occ_sum += len(resident)
                if speculative:
                    sched_spec_sum += sum(1 for e in resident if e.s.wrong_path)
            rob_occ_sum += len(rob) - rob_head
            if speculative:
                rob_spec_sum += sum(1 for x in rob[rob_head:] if x.wrong_path)

            # Collect eligible entries (oldest first).
            resident.sort(key=lambda e: e.idx)
            eligible = []
            for e in resident:
                if e.issued or e.ready_cycle > cyc:
                    continue
                s = e.s
                if not self._src_ready(s, cyc):
                    issue_block["sources pending"] += 1
                    continue
                i = e.idx
                # Persistent hard barrier: only at the ROB head.
                if s.persistent_hard:
                    if s.uid != head_uid:
                        issue_block["RETIRE_HEAD_REQUIRED"] += 1
                        continue
                elif oldest_persist is not None and i > oldest_persist:
                    # Blocked by an older un-issued persistent barrier.
                    issue_block["PERSISTENT_BARRIER"] += 1
                    continue
                # Branch order: resolve conditional branches in program order.
                if s.klass == BRANCH and oldest_branch is not None and i > oldest_branch:
                    issue_block["BRANCH_ORDER"] += 1
                    continue
                # Memory ordering.
                if s.klass == STORE:
                    # Stores launch at the LSQ head: oldest un-issued memory op,
                    # and past older branches (approx past-speculation).
                    if cfg.store_at_lsq_head and oldest_mem is not None and i > oldest_mem:
                        issue_block["OLDER_MEMORY"] += 1
                        continue
                    if oldest_branch is not None and i > oldest_branch:
                        issue_block["OLDER_CONTROL"] += 1
                        continue
                elif s.klass == LOAD:
                    # Load may pass older loads but not an older un-issued store
                    # (store->load ordering; the load conflict detector).
                    if cfg.in_order_memory and oldest_store is not None and i > oldest_store:
                        issue_block["OLDER_MEMORY"] += 1
                        continue
                eligible.append(e)

            # Assign to pipes, oldest first, capped by issue_width.
            pipe_busy = [False, False, False, False]
            issued_this = 0
            for e in eligible:
                if issued_this >= cfg.issue_width:
                    issue_block["ISSUE_WIDTH"] += 1
                    continue
                cands = _pipes_for(e.s.klass)
                chosen = -1
                # Flexible ALU: take the less-contended EX pipe (EX0 first,
                # since branches/jumps also want EX1).
                for p in cands:
                    if not pipe_busy[p]:
                        chosen = p
                        break
                if chosen < 0:
                    issue_block["PIPE_CONFLICT"] += 1
                    continue
                pipe_busy[chosen] = True
                pipe_busy_cycles[chosen] += 1
                e.issued = True
                e.s.s_issue = cyc
                e.s.s_pipe = chosen
                e.s.s_complete = cyc + self._lat(e.s)
                issued_this += 1
                if do_squash and e.s.uid in squash_members \
                        and e.s.uid not in squash_frontend:
                    pending_squash.append(
                        (e.s.uid, e.s.s_complete
                         + cfg.mispredict_redirect_delay + cfg.squash_delay))
            issue_hist[issued_this] += 1

            # Release issued scheduler entries (physical rename frees the slot
            # at the issue handshake; the ROB retains the instruction).
            if issued_this:
                resident = [e for e in resident if not e.issued]

        span = max(1, cyc)
        arch = sum(1 for s in stream if not s.wrong_path)
        self.stats = {
            "cycles": cyc,
            "retired": retired_n,
            "squashed": squashed_n,
            "n": n,
            "arch": arch,
            "issue_hist": issue_hist,
            "retire_hist": retire_hist,
            "admit_hist": admit_hist,
            "admitted": admit_ptr,
            "completed_all": done_n == n,
            "pipe_busy": pipe_busy_cycles,
            "pipe_util": [round(100.0 * b / span, 1) for b in pipe_busy_cycles],
            "sched_occ_avg": round(sched_occ_sum / span, 1),
            "rob_occ_avg": round(rob_occ_sum / span, 1),
            "sched_spec_avg": round(sched_spec_sum / span, 1),
            "rob_spec_avg": round(rob_spec_sum / span, 1),
            "admit_stall": admit_stall,
            "issue_block": issue_block,
            "arch_ipc": round(arch / span, 4),
        }
        return self.stats


def backend_report(stats, cfg, golden_span=None, label="backend-only run"):
    """Where a backend fed at full rate actually loses its cycles."""
    span = max(1, stats["cycles"])
    out = ["== %s ==  (%s)" % (label, cfg.describe())]
    if not stats["completed_all"]:
        out.append("!! INCOMPLETE: %d of %d stream instructions left"
                   % (stats["n"] - stats["retired"] - stats["squashed"],
                      stats["n"]))
    out.append("span: %d cycles%s" % (
        stats["cycles"],
        "" if golden_span is None else
        "   golden: %d   delta: %+d (%.2f%%)" % (
            golden_span, stats["cycles"] - golden_span,
            100.0 * (stats["cycles"] - golden_span) / golden_span)))
    out.append("stream %d = %d architectural + %d shadow;  retired %d, "
               "squashed %d" % (stats["n"], stats["arch"],
                                stats["n"] - stats["arch"], stats["retired"],
                                stats["squashed"]))
    out.append("architectural IPC: %.3f  (retire ceiling %d)"
               % (stats["arch_ipc"], cfg.retire_width))
    out.append("pipe util EX0/EX1/MEM0/MEM1 = %s" % stats["pipe_util"])
    out.append("occupancy: scheduler %.1f of %d (%.1f speculative), "
               "ROB %.1f of %d (%.1f speculative)" % (
                   stats["sched_occ_avg"], cfg.eff_sched_depth(),
                   stats["sched_spec_avg"], stats["rob_occ_avg"],
                   cfg.eff_rob_depth(), stats["rob_spec_avg"]))
    out.append("")
    total = cfg.decode_width * span
    out.append("  admission slots (%d cycles x %d wide = %d)"
               % (span, cfg.decode_width, total))
    for k, v in sorted(stats["admit_stall"].items(), key=lambda kv: -kv[1]):
        if v:
            out.append("    %-24s %10d %6.1f%%" % (k, v, 100.0 * v / total))
    out.append("")
    out.append("  issue: resident entries blocked, by first failing gate")
    tot = sum(stats["issue_block"].values()) or 1
    for k, v in sorted(stats["issue_block"].items(), key=lambda kv: -kv[1]):
        if v:
            out.append("    %-24s %10d %6.1f%%" % (k, v, 100.0 * v / tot))
    out.append("")
    out.append("  cycles issuing 0/1/2/3: %s" % stats["issue_hist"])
    out.append("  cycles retiring 0/1/2/3: %s" % stats["retire_hist"])
    return "\n".join(out)
