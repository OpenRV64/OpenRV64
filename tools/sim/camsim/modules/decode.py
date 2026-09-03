"""Decode: turn a fetched word into an operation.

``casim.frontend._fill`` did this inline at the admission gate, mixed with
path binding.  Separated, it is the one genuinely stateless unit in the
frontend -- a pure function of the instruction word -- which is why it is the
easiest to swap: pass a different ``decoder`` and the rest of the machine does
not notice.

The decoder itself is a constructor argument rather than an import.  The ISA
tables live in ``casim.isa`` and duplicating them would be waste, but a module
that hard-coded that import would drag the whole of casim behind it wherever it
went, including out to the far end of a pipe.  Graph assembly picks the
decoder; the unit only knows it has one.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE


class Op(object):
    """A decoded candidate.  Carries the fetch identity forward unchanged, so
    a consumer can still say which fetch slot it came from."""

    __slots__ = ("cand", "klass", "rd", "rs1", "rs2", "uses_rs1", "uses_rs2",
                 "reg_write", "is_hard", "is_control", "is_jalr",
                 "persistent_hard")

    def __init__(self, cand):
        self.cand = cand

    @property
    def uid(self):
        return self.cand.uid

    @property
    def pc(self):
        return self.cand.pc

    @property
    def instr(self):
        return self.cand.instr

    def __eq__(self, other):
        return isinstance(other, Op) and other.cand.uid == self.cand.uid

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return self.cand.uid

    def __repr__(self):
        return "op%d@%x" % (self.cand.uid, self.cand.pc)


def default_decoder():
    """casim's ISA tables, bound at graph assembly rather than at import."""
    from casim import isa
    from casim.stream import BRANCH, JUMP

    def decode(op):
        (klass, rd, rs1, rs2, u1, u2, rw, hard) = isa.decode(op.instr)
        op.klass, op.rd, op.rs1, op.rs2 = klass, rd, rs1, rs2
        op.uses_rs1, op.uses_rs2, op.reg_write, op.is_hard = u1, u2, rw, hard
        op.is_control = isa.is_control(op.instr)
        op.is_jalr = (op.instr & 0x7F) == isa.OP_JALR
        op.persistent_hard = hard and klass not in (BRANCH, JUMP)
        return op
    return decode


class Decode(Module):
    """Decode every candidate fetch offers, in the cycle it offers them."""

    name = "decode"
    publishes = [out("decode.ops", ASYNC, PULSE, doc="decoded, in fetch order")]
    subscribes = ["fetch.cands"]

    def __init__(self, decoder=None, width=None, name=None):
        self._decode = decoder
        self.width = width
        Module.__init__(self, name)

    def build(self, bus):
        self.S_IN = bus.signal("fetch.cands")
        self.S_OUT = bus.signal("decode.ops")
        if self._decode is None:
            self._decode = default_decoder()
        self._cache = {}          # uid -> Op, so a re-settle is free and equal
        self.count = 0

    def settle(self, bus):
        cands = bus.get(self.S_IN)
        if not cands:
            bus.pub(self.S_OUT, None)
            return
        if self.width is not None:
            cands = cands[:self.width]
        ops = []
        for c in cands:
            op = self._cache.get(c.uid)
            if op is None:
                op = self._decode(Op(c))
                self._cache[c.uid] = op
            ops.append(op)
        bus.pub(self.S_OUT, ops)

    def tick(self, bus):
        if bus.resetting():
            self._cache.clear()
            self.count = 0
            return
        ops = bus.get(self.S_OUT)
        if ops:
            self.count += len(ops)
        # The cache only has to outlive the cycle its candidates were offered
        # in; anything older has been taken or squashed.
        if len(self._cache) > 4096:
            self._cache.clear()

    def report(self):
        return {"decoded": self.count}
