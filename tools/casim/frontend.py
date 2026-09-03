"""Per-cycle frontend model: PC generation, fetch supply, redirect.

This is the other half of `machine.py`.  Where the backend model consumes
a frontend stream and asks what the scheduler/ROB/pipes do with it, this
model produces that stream and asks how fast the frontend can deliver
it -- fetch block supply, 3-wide candidate presentation, and the redirect
behaviour of predicted-taken transfers and mispredicts.  Its cutoff is
the backend admission gate: it delivers candidates to the gate, and what
happens after that is not its problem.

The gate is a policy object, which is what makes a decoupled run
possible:

  * `IdealGate` always accepts, so the frontend never sees backpressure.
    That is frontend-only mode -- the frontend's own speed limit.
  * `GoldenGate` accepts each instruction no earlier than the cycle the
    golden admitted it, re-imposing the real backend's backpressure.
    That is the validation mode: with the output side pinned to the
    golden, delivery timing has to reproduce the golden's, which is what
    makes the ideal-gate number mean anything.

Timing constants are measured from the golden traces, not assumed.  On
`pipeline-state-52448` (bp8): a redirect on a predicted-taken transfer
lands one cycle after the transfer is admitted (73% at +1, 26% at +2),
and a mispredict redirect delivers the corrected path one cycle after the
branch completes (99% at +1).  Both are `Config` knobs.

Branch outcomes and per-branch resolve latency are replayed from a
`btrace.BranchTrace`.  A frontend with no backend attached cannot resolve
a branch for itself; replaying the golden's latency is the honest
default, and `Config.resolve_latency` overrides it with a constant to ask
what the frontend would do if resolution were faster.
"""

from . import isa
from .stream import SInsn, BRANCH, JUMP

_MASK = 0xFFFFFFFFFFFFFFFF

# Why the frontend delivered nothing in a cycle.  Exclusive, tested in
# this order, mirroring the trace's own reason discipline.
(FS_DELIVER, FS_GATE, FS_REDIRECT, FS_REFILL, FS_IMAGE) = range(5)
FS_NAMES = {
    FS_DELIVER: "delivering",
    FS_GATE: "gate backpressure (backend)",
    FS_REDIRECT: "redirect bubble (nothing to present)",
    FS_REFILL: "fetch block not resident",
    FS_IMAGE: "wrong path ran off the fetch image",
}


class IdealGate(object):
    """A backend that never backpressures: the frontend-only cutoff."""

    def accept(self, s, cycle):
        return True


class GoldenGate(object):
    """Replay the golden's admission timing, to validate delivery.

    Only the architectural path is identity-matched, by position in the
    architectural stream: that sequence is deterministic, so instruction
    *i* is the same instruction in both runs.  Shadow work is not
    matched -- a one-cycle difference in redirect timing changes how many
    candidates a shadow holds, so pairing them up by fetch position
    desynchronises permanently and measures nothing.  Shadow candidates
    are admitted freely instead, which is what the real gate did with
    them, and they are checked in aggregate: how many were fetched, and
    how many were discarded before admission.

    An architectural instruction is admitted no earlier than the cycle
    the golden admitted it, so the frontend model carries the real
    backend's backpressure and its delivery timing has to reproduce the
    golden's on its own.
    """

    def __init__(self, decode_cycle_by_uid, shadow_admits_per_cycle=None):
        self.dc = decode_cycle_by_uid
        # Per cycle, how many *shadow* candidates the golden admitted.
        # Without this the model's speculation is unthrottled and it
        # fetches far more of it than the real machine had room for; with
        # a single shared budget instead, shadow work crowds out the
        # architectural path and the replay falls permanently behind.
        # Architectural instructions therefore follow their own golden
        # admission cycle, and shadow work gets exactly the leftover
        # capacity the golden gave its own.
        self.shadow_budget = shadow_admits_per_cycle or {}
        self.cycle = None
        self.left = 0
        self.paced = 0
        self.free = 0

    def accept(self, s, cycle):
        if cycle != self.cycle:
            self.cycle = cycle
            self.left = self.shadow_budget.get(cycle, 0)
        if s.wrong_path or s.golden_uid is None:
            if self.shadow_budget and self.left <= 0:
                return False
            self.left -= 1
            self.free += 1
            return True
        self.paced += 1
        want = self.dc.get(s.golden_uid)
        return want is None or cycle >= want


class FrontendResult(object):
    __slots__ = ("stream", "fetched", "delivered", "wrong_path", "discarded",
                 "cycles", "stalls", "redirects", "image_misses", "stats",
                 "complete")

    def __init__(self):
        self.stream = []          # delivered SInsn, in fetch order
        self.fetched = 0
        self.delivered = 0
        self.wrong_path = 0
        self.discarded = 0        # fetched, squashed before admission
        self.cycles = 0
        self.stalls = {}
        self.redirects = {}
        self.image_misses = 0
        self.complete = False
        self.stats = {}


class _Redirect(object):
    __slots__ = ("cycle", "owner", "target", "kind", "to_correct_path")

    def __init__(self, cycle, owner, target, kind, to_correct_path):
        self.cycle = cycle
        self.owner = owner
        self.target = target
        self.kind = kind
        # True when the redirect puts the frontend back on the
        # architectural path; a wrong path that redirects within itself
        # is still a wrong path.
        self.to_correct_path = to_correct_path


class Frontend(object):
    def __init__(self, cfg, btrace, gate=None, golden_stream=None):
        self.cfg = cfg
        self.bt = btrace
        self.gate = gate or IdealGate()
        # Correct-path instructions reuse the golden's ROB-derived
        # register info where it exists; the encoding decode is the
        # fallback and the only source for synthesised wrong-path work.
        self.golden = golden_stream or []
        self.decode_disagreements = 0
        self.pc_mismatches = 0
        self.event_pc_mismatches = 0

    def _block(self, pc):
        return pc // self.cfg.fetch_block_bytes

    def _request(self, blk, cyc, resident):
        """Bring a fetch block into the resident window if it is not there.

        The carousel is a small direct-mapped window over fetch blocks, so
        a block displaces whatever shares its slot rather than joining an
        unbounded set.  Returns the cycle the block becomes usable.
        """
        slot = blk % self.cfg.fetch_window_blocks
        have = resident.get(slot)
        if have is not None and have[0] == blk:
            return have[1]
        ready = cyc + self.cfg.l1i_refill_cycles
        resident[slot] = (blk, ready)
        return ready

    def run(self, max_cycles=4_000_000):
        cfg = self.cfg
        bt = self.bt
        image = bt.image
        events = bt.events
        n_ev = len(events)
        gate = self.gate
        golden = self.golden
        n_golden = len(golden)
        res = FrontendResult()
        stream = res.stream

        pc = bt.entry_pc or 0
        ev_i = 0                # next unconsumed redirect event
        out = []                # presented, not yet admitted (fetch order)
        pending = []            # list[_Redirect]
        resident = {}           # block -> cycle it becomes usable
        shadow_owner = None     # uid of the control whose shadow we are in
        shadow_admitted = []    # admitted shadow work not yet attributed
        path_owner = 0          # uid of the redirect that opened this segment
        segment = 0
        uid = 0
        stalls = {}
        redirects = {}
        want_arch = bt.arch_count or 0
        arch_done = 0
        cyc = 0

        while cyc < max_cycles:
            cyc += 1
            reason = None

            # (1) Land any redirect due this cycle.  The oldest owner
            # wins: an older branch's resolve supersedes a younger
            # branch's prediction, which is the recovery the hardware
            # performs.
            due = [r for r in pending if r.cycle <= cyc]
            if due:
                win = min(due, key=lambda r: r.owner)
                pending = [r for r in pending
                           if r.cycle > cyc and r.owner <= win.owner]
                for s in out:
                    if s.uid > win.owner:
                        res.discarded += 1
                out = [s for s in out if s.uid <= win.owner]
                # Shadow work already through the gate is the backend's
                # problem now: record which redirect takes it away, and
                # whether that redirect is raised by the frontend at the
                # prediction or by the backend at resolution.  The backend
                # model needs both to know when the slots come back.
                for s in shadow_admitted:
                    if s.uid > win.owner:
                        s.squash_owner = win.owner
                        s.squash_on = ("predict" if win.kind in
                                       ("predicted-taken", "wrong-path-predict")
                                       else "resolve")
                shadow_admitted = [s for s in shadow_admitted
                                   if s.squash_owner is None]
                pc = win.target
                path_owner = win.owner
                segment += 1
                if win.to_correct_path:
                    shadow_owner = None
                redirects[win.kind] = redirects.get(win.kind, 0) + 1
                reason = FS_REDIRECT

            # (2) Present up to fetch_width candidates from resident
            # blocks into the presentation queue.
            new = 0
            while new < cfg.fetch_width and len(out) < cfg.fetch_queue_depth:
                if self._request(self._block(pc), cyc, resident) > cyc:
                    if reason is None:
                        reason = FS_REFILL
                    break
                instr = image.get(pc)
                if instr is None:
                    # Off the recorded image.  Only reachable on a wrong
                    # path, where the golden never went and so never
                    # recorded the encodings.  Stop fetching; the pending
                    # resolve redirect recovers the path.
                    res.image_misses += 1
                    if reason is None:
                        reason = FS_IMAGE
                    break
                uid += 1
                s = SInsn(uid)
                s.pc = pc
                s.instr = instr
                s.fetch_cycle = cyc
                out.append(s)
                res.fetched += 1
                new += 1
                pc = (pc + 4) & _MASK
            if cfg.l1i_refill_cycles:
                # Rolling cursor: keep the blocks ahead of the fetch PC
                # requested, which is what hides refill latency on a
                # sequential stream.  Walk them oldest-first so the block
                # under the cursor is the one that survives.
                base = self._block(pc)
                for k in range(cfg.fetch_window_blocks - 1, -1, -1):
                    self._request(base + k, cyc, resident)

            # (3) The gate consumes in order, up to decode_width.
            taken = 0
            while out and taken < cfg.decode_width:
                s = out[0]
                wrong = shadow_owner is not None
                # Events are matched by position in the architectural
                # stream, never by PC: a hot loop revisits the same PC
                # thousands of times and each visit predicts separately.
                ev = None
                if (not wrong and ev_i < n_ev
                        and events[ev_i].arch_i == arch_done):
                    ev = events[ev_i]
                self._fill(s, wrong, path_owner, segment, golden, n_golden,
                           arch_done, ev)
                if not gate.accept(s, cyc):
                    if reason is None:
                        reason = FS_GATE
                    break
                out.pop(0)
                s.front_ready = cyc
                s.delivered = True
                stream.append(s)
                res.delivered += 1
                taken += 1
                if wrong:
                    res.wrong_path += 1
                    shadow_admitted.append(s)
                else:
                    arch_done += 1
                    if ev is not None:
                        ev_i += 1
                        shadow_owner = self._schedule(
                            s, ev, cyc, pending, resident, shadow_owner)
                if wrong and isa.is_control(s.instr):
                    self._schedule_wrong(s, cyc, pending, image)
            if taken:
                reason = FS_DELIVER
            elif reason is None:
                reason = FS_GATE if out else FS_REDIRECT
            stalls[reason] = stalls.get(reason, 0) + 1

            # (4) Done when the whole architectural stream has been
            # delivered and no speculative work is left in flight.
            if want_arch and arch_done >= want_arch and not pending:
                res.complete = True
                break

        res.cycles = cyc
        res.stalls = stalls
        res.redirects = redirects
        _link_dependences(stream)
        res.stats = self._summarise(res, arch_done, want_arch)
        return res

    # -- helpers -----------------------------------------------------------

    def _fill(self, s, wrong, path_owner, segment, golden, n_golden,
              arch_i, ev):
        """Decode a presented candidate and bind it to its path.

        Path membership is decided at admission, not at fetch: the
        sequential candidates presented alongside a predicted-taken
        transfer are fetched before anyone knows they are shadow work.
        """
        if s.klass is not None:
            return                       # already filled, gate refused it
        s.wrong_path = wrong
        s.resume_owner = path_owner
        s.segment = segment
        if ev is not None and ev.pc != s.pc:
            self.event_pc_mismatches += 1
        (klass, rd, rs1, rs2, u1, u2, rw, hard) = isa.decode(s.instr)
        if not wrong and arch_i < n_golden:
            g = golden[arch_i]
            if g.pc == s.pc:
                s.golden_uid = g.uid
                s.g_issue, s.g_complete = g.g_issue, g.g_complete
                s.g_retire, s.g_pipe = g.g_retire, g.g_pipe
                s.exec_lat = g.exec_lat
                if (g.klass, g.rd, g.rs1, g.rs2) != (klass, rd, rs1, rs2):
                    self.decode_disagreements += 1
                klass, rd, rs1, rs2 = g.klass, g.rd, g.rs1, g.rs2
                u1, u2 = g.uses_rs1, g.uses_rs2
                rw, hard = g.reg_write, g.is_hard
            else:
                self.pc_mismatches += 1
        s.klass = klass
        s.rd, s.rs1, s.rs2 = rd, rs1, rs2
        s.uses_rs1, s.uses_rs2, s.reg_write, s.is_hard = u1, u2, rw, hard
        s.is_jalr = (s.instr & 0x7F) == isa.OP_JALR
        s.persistent_hard = hard and klass not in (BRANCH, JUMP)
        s.retired = not wrong

    def _schedule(self, s, e, cyc, pending, resident, shadow_owner):
        """Queue the redirects an admitted architectural transfer raises.

        Returns the new shadow owner.  Four cases, all visible in the
        golden: predicted not-taken and right (no redirect, no shadow);
        predicted not-taken and wrong (shadow opens immediately, closes
        on resolve); predicted taken and right (shadow until the
        prediction redirects); predicted taken and wrong (shadow until
        resolve, through the predicted target).
        """
        cfg = self.cfg
        seq = (s.pc + 4) & _MASK
        predicted_elsewhere = not e.implicit and e.pred_next_pc != seq
        # An implicit event always needs a resolve-time redirect even
        # when it lands back on its own successor: a serialising CSR
        # write or fence refetches pc+4 and throws away the prefix it
        # had already fetched, which the mispredict test cannot see.
        mispredicted = e.mispredicted or e.implicit
        if predicted_elsewhere:
            pending.append(_Redirect(
                cyc + cfg.taken_redirect_delay, s.uid, e.pred_next_pc,
                "predicted-taken", not mispredicted))
            if cfg.l1i_refill_cycles and cfg.stash_unpredicted:
                self._request(self._block(seq), cyc, resident)
        if mispredicted:
            lat = cfg.resolve_latency or e.resolve_lat or 1
            pending.append(_Redirect(
                cyc + lat + cfg.mispredict_redirect_delay, s.uid, e.next_pc,
                "implicit-redirect" if e.implicit else "mispredict", True))
        if predicted_elsewhere or mispredicted:
            return s.uid if shadow_owner is None else shadow_owner
        return shadow_owner

    def _schedule_wrong(self, s, cyc, pending, image):
        """Predict a control transfer the machine has no record of.

        On a wrong path there is no architectural outcome to replay, so
        direct transfers use a static backward-taken rule and indirect
        ones fall through.  This only decides which garbage fills the
        shadow; the count of instructions it produces is reported so the
        approximation stays visible.
        """
        tgt = isa.taken_target(s.pc, s.instr)
        if tgt is None:
            return
        op = s.instr & 0x7F
        if op == isa.OP_JAL or tgt < s.pc:
            if tgt in image:
                pending.append(_Redirect(
                    cyc + self.cfg.taken_redirect_delay, s.uid, tgt,
                    "wrong-path-predict", False))

    def _summarise(self, res, arch_done, want_arch):
        span = max(1, res.cycles)
        correct = res.delivered - res.wrong_path
        return {
            "cycles": res.cycles,
            "fetched": res.fetched,
            "delivered": res.delivered,
            "correct_path": correct,
            "arch_delivered": arch_done,
            "arch_expected": want_arch,
            "wrong_path": res.wrong_path,
            "discarded": res.discarded,
            "deliver_ipc": round(res.delivered / span, 4),
            "correct_ipc": round(correct / span, 4),
            "image_misses": res.image_misses,
            "decode_disagreements": self.decode_disagreements,
            "pc_mismatches": self.pc_mismatches,
            "event_pc_mismatches": self.event_pc_mismatches,
            "complete": res.complete,
        }


def _link_dependences(stream):
    """Last-writer walk over the speculative stream, with rollback.

    Wrong-path instructions may read wrong-path producers, but a
    correct-path instruction after a squash must not: the rename map
    rolls back to the redirect owner, which is what the hardware
    recovers.  A snapshot is kept per instruction and restored whenever
    the stream resumes from that instruction's redirect.
    """
    last = [None] * 32
    snapshots = {0: list(last)}
    cur_seg = 0
    for s in stream:
        if s.segment != cur_seg:
            snap = snapshots.get(s.resume_owner)
            if snap is not None:
                last = list(snap)
            cur_seg = s.segment
        s.src1_uid = last[s.rs1] if (s.uses_rs1 and s.rs1) else None
        s.src2_uid = last[s.rs2] if (s.uses_rs2 and s.rs2) else None
        if s.reg_write and s.rd:
            last[s.rd] = s.uid
        snapshots[s.uid] = list(last)
    return stream


def report(res, cfg, golden_span=None, golden_fetched=None,
           golden_discarded=None):
    span = max(1, res.cycles)
    st = res.stats
    out = ["== frontend-only run ==  (%s)" % cfg.describe_frontend()]
    if not res.complete:
        out.append("!! INCOMPLETE: delivered %d of %d architectural "
                   "instructions before the cycle cap" % (
                       st["arch_delivered"], st["arch_expected"]))
    out.append("span: %d cycles%s" % (
        res.cycles,
        "" if golden_span is None else
        "   golden: %d   delta: %+d (%.2f%%)" % (
            golden_span, res.cycles - golden_span,
            100.0 * (res.cycles - golden_span) / golden_span)))
    out.append("fetched %d%s   delivered %d = %d correct-path + %d shadow"
               "   squashed before admission %d%s" % (
                   res.fetched,
                   "" if golden_fetched is None else " (golden %d)" % golden_fetched,
                   res.delivered, st["correct_path"], res.wrong_path,
                   res.discarded,
                   "" if golden_discarded is None else " (golden %d)" % golden_discarded))
    out.append("delivery: %.3f insn/cyc total, %.3f correct-path "
               "(gate ceiling %d)" % (st["deliver_ipc"], st["correct_ipc"],
                                      cfg.decode_width))
    out.append("")
    out.append("  %-38s %8s %7s" % ("cycles spent", "cycles", "%"))
    for k in sorted(res.stalls, key=lambda k: -res.stalls[k]):
        out.append("  %-38s %8d %6.1f%%" % (
            FS_NAMES.get(k, k), res.stalls[k], 100.0 * res.stalls[k] / span))
    out.append("")
    out.append("  %-38s %8s" % ("redirects", "count"))
    for k in sorted(res.redirects, key=lambda k: -res.redirects[k]):
        out.append("  %-38s %8d" % (k, res.redirects[k]))
    notes = []
    if res.image_misses:
        notes.append("%d wrong-path fetches ran off the recorded image (the "
                     "golden never went there, so no encoding exists); those "
                     "paths stall until their resolve redirect."
                     % res.image_misses)
    if st["decode_disagreements"]:
        notes.append("%d correct-path instructions where the encoding decode "
                     "disagreed with the golden ROB info (golden wins)."
                     % st["decode_disagreements"])
    if st["pc_mismatches"]:
        notes.append("%d correct-path instructions did not line up with the "
                     "golden architectural stream -- the replay diverged."
                     % st["pc_mismatches"])
    if st["event_pc_mismatches"]:
        notes.append("%d redirect events fired at a PC other than the one "
                     "recorded -- the replay diverged."
                     % st["event_pc_mismatches"])
    if notes:
        out.append("")
        out.extend("  note: " + s for s in notes)
    return "\n".join(out)
