"""Branch prediction, modelled on ``rtl/core/exec/bp``.

The RTL numbers its predictors; ``bp8`` is ``OPENRV64_BP_TOURNAMENT_BTB`` and is
the production default, which is also the one the committed golden traces were
captured with -- so it is the one worth modelling first.  ``bp9`` is TAGE and
is not implemented here.

Geometry and index functions are the RTL's, not chosen:

  global   2048-entry PHT, 3-bit counters, 11-bit GHR
           index = (pc >> 2)[10:0] ^ ghr[10:0]
  local    512-entry history table of 10-bit histories, index = (pc >> 2)[8:0]
           1024-entry PHT, 3-bit counters, index = history[9:0]
  chooser  512 entries, 2-bit counters, index = (pc >> 2)[8:0]; the MSB selects
           local
  BTB      256 entries, 16-bit tags, index = (pc >> 2)[7:0],
           tag = (pc >> 10)[15:0]; consulted for indirect transfers only

Two details that matter more than the sizes:

**A cold entry falls back to backward-taken.**  ``global_prediction`` and
``local_prediction`` in the RTL read the counter only when the valid bit is
set, and otherwise take ``lookup_backward_i``.  So a predictor that has never
seen a branch behaves exactly like the static rule -- which is why BTFN was
worth measuring separately, and why the tournament only beats it once it has
trained.

**The chooser only trains when the two components disagree.**  The RTL sets
``chooser_valid_q`` on resolution only under
``global_prediction != local_prediction``; when both agree there is nothing to
choose between and updating would be noise.

The GHR here is the committed one.  The RTL keeps a speculative GHR and repairs
it from the in-flight queue on a flush; that machinery decides *how fast* the
history recovers after a mispredict, not what is predicted on a steady path,
and it is left out.  It is the first thing to add if predicted-taken accuracy
comes out high but mispredict recovery looks wrong.
"""

from .rv64 import (OP_BRANCH, OP_JAL, OP_JALR, imm_b, imm_j, opcode)

MASK = 0xFFFFFFFFFFFFFFFF

BP_STALL, BP_ALWAYS_BRANCH, BP_ALWAYS_DECLINE, BP_REPEAT_LAST = 0, 1, 2, 3
BP_BTFNT, BP_BIMODAL, BP_GSHARE_BTB, BP_GSHARE_BTB_512 = 4, 5, 6, 7
BP_TOURNAMENT_BTB, BP_TAGE_BTB = 8, 9


def _sat_up(v, bits):
    top = (1 << bits) - 1
    return v + 1 if v < top else v


def _sat_down(v):
    return v - 1 if v > 0 else v


class Tournament(object):
    """bp8: tournament direction predictor, BTB for indirect, RAS for returns.

    Not a module.  Prediction is a lookup the fetch unit does and training is
    something retirement does, so making it a unit would put a signal on both
    sides of a table that only ever has one reader and one writer.  It is
    state that two units share, like the register file -- and like the register
    file, exactly one of them writes it.
    """

    def __init__(self, global_entries=2048, global_bits=3, ghr_bits=11,
                 local_entries=512, local_hist_bits=10, local_pht=1024,
                 local_bits=3, chooser_entries=512, chooser_bits=2,
                 btb_entries=256, btb_tag_bits=16, ras_depth=16):
        self.g_n, self.g_bits, self.ghr_bits = global_entries, global_bits, ghr_bits
        self.l_n, self.l_hist_bits = local_entries, local_hist_bits
        self.lp_n, self.l_bits = local_pht, local_bits
        self.c_n, self.c_bits = chooser_entries, chooser_bits
        self.btb_n, self.btb_tag_bits = btb_entries, btb_tag_bits
        self.ras_depth = ras_depth
        self.reset()

    def reset(self):
        g_init = 1 << (self.g_bits - 1)
        l_init = 1 << (self.l_bits - 1)
        self.g_ctr = [g_init] * self.g_n
        self.g_valid = [False] * self.g_n
        self.ghr = 0
        self.l_hist = [0] * self.l_n
        self.l_hist_valid = [False] * self.l_n
        self.l_ctr = [l_init] * self.lp_n
        self.l_valid = [False] * self.lp_n
        # CHOOSER_WEAK_GLOBAL: the MSB clear means "use global".
        self.c_ctr = [(1 << (self.c_bits - 1)) - 1] * self.c_n
        self.c_valid = [False] * self.c_n
        self.btb_tag = [None] * self.btb_n
        self.btb_target = [0] * self.btb_n
        self.ras = []
        self.lookups = 0
        self.trained = 0
        self.hits = 0
        self.btb_hits = 0
        self.btb_misses = 0
        self.ras_hits = 0

    # -- index functions, straight from the RTL ---------------------------
    def _gi(self, pc):
        return ((pc >> 2) ^ self.ghr) & (self.g_n - 1)

    def _lhi(self, pc):
        return (pc >> 2) & (self.l_n - 1)

    def _lpi(self, hist):
        return hist & (self.lp_n - 1)

    def _ci(self, pc):
        return (pc >> 2) & (self.c_n - 1)

    def _bi(self, pc):
        return (pc >> 2) & (self.btb_n - 1)

    def _bt(self, pc):
        shift = 2 + (self.btb_n - 1).bit_length()
        return (pc >> shift) & ((1 << self.btb_tag_bits) - 1)

    # -- prediction --------------------------------------------------------
    @staticmethod
    def is_link(r):
        return r in (1, 5)

    def predict(self, pc, instr):
        """Return (next_pc, record) where record is what training needs.

        The record is the *prediction-time* state: the indices consulted and
        the local history as it was.  Training against a fresh lookup would
        update a different entry than the one that made the prediction, which
        is the bug the RTL avoids by carrying the same values in its in-flight
        queue.

        **Pure.**  Fetch calls this from its settling function, which the bus
        re-runs whenever an input moves, so anything mutated here would be
        mutated several times per cycle -- a return-address stack pushed three
        times for one call.  The speculative side effects are applied once, in
        ``speculate``."""
        op = opcode(instr)
        seq = (pc + 4) & MASK
        rec = {"pc": pc, "instr": instr, "cond": False, "taken": False,
               "gi": 0, "lhi": 0, "lpi": 0, "ci": 0, "hist": 0,
               "g_pred": False, "l_pred": False, "ghr": self.ghr,
               "push": None, "pop": False, "btb": None}
        rd, rs1 = (instr >> 7) & 0x1F, (instr >> 15) & 0x1F
        if op == OP_JAL:
            rec["push"] = seq if self.is_link(rd) else None
            return (pc + imm_j(instr)) & MASK, rec
        if op == OP_JALR:
            is_return = self.is_link(rs1) and not self.is_link(rd)
            rec["push"] = seq if self.is_link(rd) else None
            if is_return and self.ras:
                rec["pop"] = True
                return self.ras[-1], rec
            i = self._bi(pc)
            rec["btb"] = self.btb_tag[i] == self._bt(pc)
            return (self.btb_target[i] if rec["btb"] else seq), rec
        if op != OP_BRANCH:
            return seq, rec

        off = imm_b(instr)
        backward = off < 0                    # the RTL's lookup_backward_i
        gi = self._gi(pc)
        lhi = self._lhi(pc)
        hist = self.l_hist[lhi] if self.l_hist_valid[lhi] else 0
        lpi = self._lpi(hist)
        ci = self._ci(pc)
        # A cold component predicts the static rule, exactly as the RTL does.
        g_pred = (self.g_ctr[gi] >> (self.g_bits - 1)) & 1 \
            if self.g_valid[gi] else backward
        l_pred = (self.l_ctr[lpi] >> (self.l_bits - 1)) & 1 \
            if self.l_valid[lpi] else backward
        c = self.c_ctr[ci] if self.c_valid[ci] else (1 << (self.c_bits - 1)) - 1
        use_local = (c >> (self.c_bits - 1)) & 1
        taken = bool(l_pred if use_local else g_pred)
        rec.update({"cond": True, "taken": taken, "gi": gi, "lhi": lhi,
                    "lpi": lpi, "ci": ci, "hist": hist,
                    "g_pred": bool(g_pred), "l_pred": bool(l_pred)})
        return ((pc + off) & MASK if taken else seq), rec

    def speculate(self, rec):
        """Apply the speculative side effects of one prediction, exactly once.

        The return-address stack is speculative state: it is pushed and popped
        down the predicted path and repaired when that path turns out wrong.
        Doing it here rather than in ``predict`` is what keeps one instruction
        from pushing three times."""
        if rec.get("pop") and self.ras:
            self.ras.pop()
            self.ras_hits += 1
        if rec.get("push") is not None:
            self.ras.append(rec["push"])
            del self.ras[:-self.ras_depth]
        if rec.get("btb") is True:
            self.btb_hits += 1
        elif rec.get("btb") is False:
            self.btb_misses += 1
        if rec["cond"]:
            self.lookups += 1

    def recover(self):
        """A redirect invalidates the speculative stack.  The RTL repairs it
        from its in-flight queue; clearing is the conservative version and
        costs return-prediction accuracy after every mispredict, which is
        visible in ``ras_hits`` rather than hidden."""
        del self.ras[:]

    # -- training ----------------------------------------------------------
    def train(self, rec, taken, target):
        """Resolution.  Called in retirement order, so the history it commits
        is the architectural one."""
        instr = rec["instr"]
        op = opcode(instr)
        if op == OP_JALR:
            if taken:
                i = self._bi(rec["pc"])
                self.btb_tag[i] = self._bt(rec["pc"])
                self.btb_target[i] = target
            return
        if not rec["cond"]:
            return
        self.trained += 1
        if rec["taken"] == taken:
            self.hits += 1

        gi, lpi, lhi, ci = rec["gi"], rec["lpi"], rec["lhi"], rec["ci"]
        self.g_valid[gi] = True
        self.l_valid[lpi] = True
        self.l_hist_valid[lhi] = True
        self.g_ctr[gi] = (_sat_up(self.g_ctr[gi], self.g_bits) if taken
                          else _sat_down(self.g_ctr[gi]))
        self.l_ctr[lpi] = (_sat_up(self.l_ctr[lpi], self.l_bits) if taken
                           else _sat_down(self.l_ctr[lpi]))
        # The chooser only learns where the two components disagreed; when
        # they agree there is nothing to choose between.
        if rec["g_pred"] != rec["l_pred"]:
            self.c_valid[ci] = True
            if rec["l_pred"] == taken:
                self.c_ctr[ci] = _sat_up(self.c_ctr[ci], self.c_bits)
            else:
                self.c_ctr[ci] = _sat_down(self.c_ctr[ci])
        self.l_hist[lhi] = ((rec["hist"] << 1) | (1 if taken else 0)) \
            & ((1 << self.l_hist_bits) - 1)
        self.ghr = ((self.ghr << 1) | (1 if taken else 0)) \
            & ((1 << self.ghr_bits) - 1)

    def report(self):
        n = self.trained
        return {"kind": "bp8 tournament+btb",
                "probed": self.lookups, "resolved": n,
                "accuracy": round(self.hits / float(n), 4) if n else None,
                "btb_hits": self.btb_hits, "btb_misses": self.btb_misses,
                "ras_hits": self.ras_hits}


class Btfnt(object):
    """bp4: backward taken, forward not taken.  The static rule the tournament
    falls back to on a cold entry, kept so the two can be compared."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.lookups = self.trained = self.hits = 0
        self.ras = []

    def predict(self, pc, instr):
        op = opcode(instr)
        seq = (pc + 4) & MASK
        rec = {"pc": pc, "instr": instr, "cond": False, "taken": False}
        if op == OP_JAL:
            return (pc + imm_j(instr)) & MASK, rec
        if op == OP_JALR:
            return seq, rec
        if op != OP_BRANCH:
            return seq, rec
        off = imm_b(instr)
        taken = off < 0
        rec.update({"cond": True, "taken": taken})
        return ((pc + off) & MASK if taken else seq), rec

    def speculate(self, rec):
        if rec["cond"]:
            self.lookups += 1

    def recover(self):
        pass

    def train(self, rec, taken, target):
        if not rec["cond"]:
            return
        self.trained += 1
        if rec["taken"] == taken:
            self.hits += 1

    def report(self):
        n = self.trained
        return {"kind": "bp4 btfnt", "probed": self.lookups, "resolved": n,
                "accuracy": round(self.hits / float(n), 4) if n else None}


def make(kind):
    if kind in ("bp8", "tournament", BP_TOURNAMENT_BTB):
        return Tournament()
    if kind in ("bp4", "btfn", "btfnt", BP_BTFNT):
        return Btfnt()
    raise ValueError("unimplemented predictor %r (bp9/TAGE is not modelled)"
                     % (kind,))


class Oracle(object):
    """A predictor that is never wrong, for attributing squash to prediction.

    Takes the architectural next-PC sequence from a recorded run and answers
    from it by instruction index. That indexing is only valid *because* it
    never mispredicts: with no wrong path, the n-th instruction fetched is the
    n-th architectural instruction, so the uid is the index. A fallible
    predictor could not be driven this way."""

    def __init__(self, control):
        self.control = control
        self.reset()

    def reset(self):
        self.lookups = self.trained = self.hits = 0
        self.missing = 0

    def predict(self, pc, instr, uid=None):
        """Perfect for *conditional branches* only.

        Not for everything: answering for MRET and CSR writes too would run
        fetch past a serialising instruction before the privilege change it
        performs has happened, and the machine faults. That is a real barrier
        the model does not enforce -- worth fixing, but not what this predictor
        is for. Jumps keep their normal handling."""
        op = opcode(instr)
        rec = {"pc": pc, "instr": instr, "cond": op == OP_BRANCH,
               "taken": False}
        if op == OP_JAL:
            return (pc + imm_j(instr)) & MASK, rec
        if op != OP_BRANCH:
            return (pc + 4) & MASK, rec
        if uid is None or uid > len(self.control) or self.control[uid-1] is None:
            self.missing += 1
            return (pc + 4) & MASK, rec
        nxt = self.control[uid - 1] & MASK
        rec["taken"] = nxt != ((pc + 4) & MASK)
        return nxt, rec

    def speculate(self, rec):
        self.lookups += 1

    def recover(self):
        pass

    def train(self, rec, taken, target):
        if not rec["cond"]:
            return
        self.trained += 1
        if rec["taken"] == taken:
            self.hits += 1

    def report(self):
        n = self.trained
        return {"kind": "oracle (conditional branches only)", "resolved": n,
                "accuracy": round(self.hits / float(n), 4) if n else None,
                "unanswered": self.missing}
