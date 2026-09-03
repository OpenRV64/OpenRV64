"""Branch trace: the control-flow record a frontend-only run replays.

A branch trace is everything the frontend model needs to reproduce a
program's fetch behaviour without a backend attached:

  * a **fetch image**, PC -> instruction word, covering every PC the
    golden run fetched (correct path and wrong path).  The frontend walks
    it to discover run lengths and to synthesise wrong-path work.
  * an ordered list of **control events**, one per architecturally
    executed control transfer, each carrying the golden's prediction, the
    architectural outcome, and the golden's resolve latency.

The event list defines the correct path exactly: replaying it in order
reproduces the same architectural instruction sequence the golden
retired.  The predictions replay too, so a frontend-only run makes the
same mistakes the real machine made and pays the same refetch, without
needing a re-implementation of the predictor.

`resolve_lat` is the one number a frontend-only run cannot compute for
itself -- a branch resolves in the backend, and in frontend-only mode
there is no backend.  Replaying the golden's per-branch latency is the
honest default; `Config.resolve_latency` overrides it with a constant to
ask what the frontend would do given faster resolution.
"""

from . import isa

MAGIC = "casim-branch-trace-v1"
_MASK = 0xFFFFFFFFFFFFFFFF


class CtrlEvent(object):
    """One architectural instruction that redirects the frontend.

    Covers every redirect the machine actually performs, which is more
    than the taken branches: a serialising CSR write or fence flushes the
    fetch prefix and refetches its own successor, with no architectural
    PC discontinuity to give it away.  Those show up here as `implicit`
    events with `next_pc == pc + 4`, and they are not free -- on the bp8
    golden the boot stub's PMP writes each discard ~35 fetched
    candidates.
    """

    __slots__ = ("arch_i", "pc", "instr", "pred_taken", "pred_next_pc",
                 "next_pc", "resolve_lat", "implicit", "shadow")

    def __init__(self, arch_i, pc, instr, pred_taken, pred_next_pc, next_pc,
                 resolve_lat, implicit=False, shadow=0):
        # Index of the redirecting instruction in the architectural
        # stream.  Events are matched by position, not by PC: a hot loop
        # revisits the same PC thousands of times and each visit predicts
        # separately.
        self.arch_i = arch_i
        self.pc = pc
        self.instr = instr
        self.pred_taken = pred_taken
        self.pred_next_pc = pred_next_pc
        self.next_pc = next_pc
        self.resolve_lat = resolve_lat
        # True for a redirect raised by something that is not a control
        # transfer: never predicted, always a resolve-time refetch.
        self.implicit = implicit
        # Candidates the golden discarded on this redirect (diagnostic).
        self.shadow = shadow

    @property
    def taken(self):
        return self.next_pc != (self.pc + 4) & _MASK

    @property
    def mispredicted(self):
        return self.pred_next_pc != self.next_pc


class BranchTrace(object):
    __slots__ = ("entry_pc", "image", "events", "source", "golden_span",
                 "golden_retired", "golden_fetched", "golden_discarded",
                 "arch_count", "notes")

    def __init__(self):
        self.entry_pc = None
        self.image = {}        # pc -> instr word
        self.events = []       # list[CtrlEvent], architectural order
        self.source = None
        self.golden_span = None
        self.golden_retired = 0
        self.golden_fetched = 0     # candidates the golden frontend exposed
        self.golden_discarded = 0   # of those, never admitted at the gate
        self.arch_count = 0         # architectural instructions to deliver
        self.notes = []

    def summary(self):
        n = len(self.events)
        mis = sum(1 for e in self.events if e.mispredicted)
        kinds = {}
        shadow = {}
        for e in self.events:
            k = "implicit" if e.implicit else {
                isa.OP_BRANCH: "cond", isa.OP_JAL: "jal",
                isa.OP_JALR: "jalr"}.get(e.instr & 0x7F, "other")
            if e.mispredicted:
                k += " mispredicted"
            kinds[k] = kinds.get(k, 0) + 1
            shadow[k] = shadow.get(k, 0) + e.shadow
        lat = sorted(e.resolve_lat for e in self.events
                     if e.resolve_lat is not None)
        out = ["branch trace from %s" % self.source,
               "  %d architectural instructions, %d redirects, %d of them "
               "mispredicted (%.2f%%)" % (self.arch_count, n, mis,
                                          100.0 * mis / (n or 1)),
               "  %d fetched candidates in the golden, %d discarded before "
               "admission" % (self.golden_fetched, self.golden_discarded)]
        out.append("  %-24s %8s %10s %8s" % ("redirect kind", "count",
                                             "discarded", "per"))
        for k in sorted(kinds, key=lambda k: -shadow[k]):
            out.append("  %-24s %8d %10d %8.1f" % (
                k, kinds[k], shadow[k], shadow[k] / kinds[k]))
        out.append("  fetch image: %d PCs (%#x..%#x), entry %#x" % (
            len(self.image), min(self.image) if self.image else 0,
            max(self.image) if self.image else 0, self.entry_pc or 0))
        if lat:
            out.append("  golden resolve latency (admit->complete): "
                       "p10=%d p50=%d p90=%d max=%d" % (
                           lat[len(lat) // 10], lat[len(lat) // 2],
                           lat[len(lat) * 9 // 10], lat[-1]))
        out.extend("  note: " + s for s in self.notes)
        return "\n".join(out)


def architectural_chain(trace):
    """The architectural instruction sequence, in fetch (= uid) order.

    Neither available signal is sufficient alone:

    * Retirement order misses instructions that leave the ROB through a
      flush instead of the ordinary handshake.  On the bp8 golden the
      boot stub's two PMP CSR writes complete, redirect the frontend, and
      never emit a RETIRE row; dropping them mis-attributes the redirect
      each one caused to its neighbour.
    * Chaining COMPLETE's next-PC field misses in the other direction:
      the field records `pc + 4` for `MRET`, whose redirect is applied by
      the exception unit rather than the completing instruction, so a
      pure next-PC walk leaves the boot stub and never comes back.

    So retirement order is the spine, and the next-PC chain only repairs
    its holes: where consecutive retired instructions are not
    architecturally adjacent, a completed instruction from the gap that
    bridges them is spliced back in.

    Returns (chain, records, unbridged) -- the architectural records in
    order, every fetched candidate in uid order, and the number of holes
    the repair could not close (each one a place where next-PC was not
    trustworthy).
    """
    recs = sorted(trace.insns.values(), key=lambda r: r.uid)
    chain = []
    unbridged = 0
    if not recs:
        return chain, recs, unbridged

    index = {r.uid: i for i, r in enumerate(recs)}
    prev = None
    for r in recs:
        if r.retire_cycle is None:
            continue
        if prev is not None:
            want = prev.next_pc if prev.next_pc is not None \
                else (prev.pc + 4) & _MASK
            if r.pc != want:
                for c in recs[index[prev.uid] + 1:index[r.uid]]:
                    if c.complete_cycle is None or c.pc != want:
                        continue
                    chain.append(c)
                    want = c.next_pc if c.next_pc is not None \
                        else (c.pc + 4) & _MASK
                    if r.pc == want:
                        break
                if r.pc != want:
                    unbridged += 1
        chain.append(r)
        prev = r
    return chain, recs, unbridged


def from_trace(trace, source=None):
    """Extract a BranchTrace from a parsed golden pipeline-state trace.

    Fetch order is uid order (the writer assigns IDs as frontend
    candidates are exposed, and the traces confirm no regressions), so
    the gap between two consecutive architectural instructions is exactly
    the work one redirect discarded, and the shape of that gap says what
    the frontend predicted.
    """
    from pipeviz.model import ROB_D0_PRED_TAKEN

    bt = BranchTrace()
    bt.source = source or trace.path
    bt.golden_span = trace.max_cycle

    chain, recs, unbridged = architectural_chain(trace)
    image = bt.image
    for r in recs:
        if r.instr:
            image.setdefault(r.pc, r.instr)
    if recs:
        bt.entry_pc = recs[0].pc

    by_uid_index = {r.uid: i for i, r in enumerate(recs)}
    no_pred_bit = 0
    for k in range(len(chain) - 1):
        a, b = chain[k], chain[k + 1]
        seq = (a.pc + 4) & _MASK
        i, j = by_uid_index[a.uid], by_uid_index[b.uid]
        shadow = recs[i + 1:j]          # candidates this redirect discarded
        control = (a.instr & 0x7F) in isa.CONTROL_OPCODES
        if not shadow and b.pc == seq:
            continue                    # straight-line: no redirect at all
        pt = None
        if a.rob_info is not None:
            pt = bool((a.rob_info >> ROB_D0_PRED_TAKEN) & 1)

        # Where the frontend went while this redirect was in flight.  The
        # shadow starts as the sequential fall-through; the first PC in it
        # that breaks the sequence is where the prediction sent fetch.
        pred = None
        prev = a.pc
        for s in shadow:
            if s.pc != (prev + 4) & _MASK:
                pred = s.pc
                break
            prev = s.pc
        if pred is None:
            if not shadow:
                pred = b.pc             # redirected with nothing in flight
            elif b.pc == seq:
                pred = seq              # serialising refetch of its own successor
            elif pt is None:
                pred = b.pc if not control else seq
                no_pred_bit += 1
            else:
                # Shadow is pure fall-through: either a correct taken
                # prediction whose redirect landed after 1-2 candidates,
                # or a not-taken prediction that had to wait for resolve.
                # The ROB's predicted-taken bit separates them.
                pred = b.pc if pt else seq

        if not control:
            # Nothing predicts a trap, an xRET or a fence refetch: the
            # frontend runs on sequentially until the redirect resolves.
            pred = seq
        lat = None
        if a.complete_cycle is not None and a.decode_cycle is not None:
            lat = max(1, a.complete_cycle - a.decode_cycle)
        bt.events.append(CtrlEvent(
            k, a.pc, a.instr, bool(pt), pred, b.pc, lat,
            implicit=not control, shadow=len(shadow)))

    # Cross-check predicted targets against the encoding for direct
    # transfers, where the answer is knowable without a BTB.
    bad = 0
    for e in bt.events:
        if e.implicit or (e.instr & 0x7F) not in (isa.OP_BRANCH, isa.OP_JAL):
            continue
        want = isa.taken_target(e.pc, e.instr) if e.pred_taken \
            else (e.pc + 4) & _MASK
        if e.pred_next_pc != want:
            bad += 1
            e.pred_next_pc = want
    if bad:
        bt.notes.append("%d direct-control predicted targets disagreed with "
                        "the encoding and were corrected (overlapping "
                        "redirects make shadow attribution ambiguous)" % bad)
    if no_pred_bit:
        bt.notes.append("%d redirects had no ROB predicted-taken bit; the "
                        "prediction was inferred from the shadow" % no_pred_bit)
    bt.arch_count = len(chain)
    bt.golden_retired = sum(1 for r in recs if r.retire_cycle is not None)
    bt.golden_fetched = len(recs)
    bt.golden_discarded = sum(1 for r in recs if r.decode_cycle is None)
    if unbridged:
        bt.notes.append("%d gaps in the retired stream could not be bridged "
                        "by the next-PC chain; those redirects may be "
                        "attributed to the wrong instruction" % unbridged)
    if bt.arch_count != bt.golden_retired:
        bt.notes.append("architectural chain is %d instructions, %d retired: "
                        "%+d completed and redirected without a RETIRE row"
                        % (bt.arch_count, bt.golden_retired,
                           bt.arch_count - bt.golden_retired))
    return bt


def write(bt, path):
    with open(path, "w") as f:
        f.write("# %s\n" % MAGIC)
        f.write("# source=%s span=%s retired=%d fetched=%d discarded=%d\n" % (
            bt.source, bt.golden_span, bt.golden_retired, bt.golden_fetched,
            bt.golden_discarded))
        for note in bt.notes:
            f.write("# note %s\n" % note)
        f.write("E %x\n" % (bt.entry_pc or 0))
        f.write("A %d\n" % bt.arch_count)
        for pc in sorted(bt.image):
            f.write("I %x %08x\n" % (pc, bt.image[pc]))
        f.write("# arch_index pc instr pred_taken pred_next next_pc "
                "resolve_lat implicit shadow\n")
        for e in bt.events:
            f.write("B %d %x %08x %d %x %x %s %d %d\n" % (
                e.arch_i, e.pc, e.instr, int(e.pred_taken), e.pred_next_pc,
                e.next_pc, "-" if e.resolve_lat is None else e.resolve_lat,
                int(e.implicit), e.shadow))


def read(path):
    bt = BranchTrace()
    bt.source = path
    with open(path) as f:
        first = f.readline()
        if MAGIC not in first:
            raise ValueError("%s: not a %s file" % (path, MAGIC))
        for line in f:
            if line.startswith("#"):
                if line.startswith("# source="):
                    for tok in line[2:].split():
                        if tok.startswith("span="):
                            v = tok[5:]
                            bt.golden_span = None if v == "None" else int(v)
                        elif tok.startswith("retired="):
                            bt.golden_retired = bt.arch_count = int(tok[8:])
                        elif tok.startswith("fetched="):
                            bt.golden_fetched = int(tok[8:])
                        elif tok.startswith("discarded="):
                            bt.golden_discarded = int(tok[10:])
                elif line.startswith("# note "):
                    bt.notes.append(line[7:].strip())
                continue
            p = line.split()
            if not p:
                continue
            if p[0] == "E":
                bt.entry_pc = int(p[1], 16)
            elif p[0] == "I":
                bt.image[int(p[1], 16)] = int(p[2], 16)
            elif p[0] == "B":
                bt.events.append(CtrlEvent(
                    int(p[1]), int(p[2], 16), int(p[3], 16), p[4] == "1",
                    int(p[5], 16), int(p[6], 16),
                    None if p[7] == "-" else int(p[7]),
                    implicit=(p[8] == "1"), shadow=int(p[9])))
            elif p[0] == "A":
                bt.arch_count = int(p[1])
    return bt
