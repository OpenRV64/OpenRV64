"""L1 cache, modelled on ``rtl/cache/l1``.

Physically tagged, set-associative, pipelined.  The policy is the RTL's, taken
from its README rather than invented:

  * read allocate;
  * **one 64-bit refill request per line beat**, so a 64-byte line costs eight
    beats from lower memory -- this is why a miss is expensive and why line
    size shows up in the cycle count rather than only in the hit rate;
  * write-through, **no write allocate** -- a store that misses does not pull
    the line in, it just goes below;
  * one accepted and one completed resident read hit per cycle;
  * ordered one-entry response buffering;
  * a failed refill never validates a partial line.

The ICX core uses 16 KiB, four ways, 64-byte lines for both L1I and L1D, so
that is the default here.  One class serves as either side: the signal names
are constructor arguments, which is the same trick ``Sram`` uses and the reason
the I-side and D-side are genuinely independent paths rather than one port with
a fairness problem.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE
from .memory import MemReq, MemResp


class Line(object):
    __slots__ = ("tag", "valid", "data", "used")

    def __init__(self):
        self.tag = None
        self.valid = False
        self.data = None
        self.used = 0


class L1(Module):
    def __init__(self, mem, req, resp, ready, name,
                 cache_bytes=16 * 1024, line_bytes=64, ways=4,
                 hit_latency=1, beat_cycles=1, write_through_cycles=1,
                 takes_stores=True, depth=8):
        self.mem = mem
        self.line_bytes = line_bytes
        self.ways = ways
        self.sets = cache_bytes // (line_bytes * ways)
        self.hit_latency = hit_latency
        # One 64-bit beat per refill: the line cost is beats * cycles, which is
        # where the RTL's per-beat refill shows up as a number.
        self.beats = line_bytes // 8
        self.beat_cycles = beat_cycles
        self.write_through_cycles = write_through_cycles
        # "one accepted and one completed resident read hit per cycle" -- the
        # RTL's L1 is a pipeline, not a blocking lookup.  Modelling it as
        # one-at-a-time serialises every access behind the last one's latency,
        # which on this workload was 97% of the LSU's occupancy.
        self.depth = depth
        self._req, self._resp, self._ready = req, resp, ready
        self.publishes = [
            # ASYNC: the answer is available in the cycle the array read
            # completes.  A registered response here is a pipeline stage the
            # hit path does not have, and it lands on every load.
            out(resp, ASYNC, PULSE, None, doc="completed access"),
            out(ready, ASYNC, LEVEL, True, doc="can accept a request"),
        ]
        # The I-side sees no stores.  Self-modifying code would need an
        # invalidate here, not a write-through, and this core fences for it.
        self.takes_stores = takes_stores
        self.subscribes = [req] + (["commit.store"] if takes_stores else [])
        Module.__init__(self, name)

    def build(self, bus):
        self.S_REQ = bus.signal(self._req)
        self.S_RESP = bus.signal(self._resp)
        self.S_READY = bus.signal(self._ready)
        self.S_ST = bus.signal("commit.store") if self.takes_stores else None
        self._reset_state()

    def _reset_state(self):
        self.tags = [[Line() for _ in range(self.ways)]
                     for _ in range(self.sets)]
        self.clock = 0
        self.pipe = []          # [(ready_cycle, MemReq, hit)] -- in flight
        self.hits = 0
        self.misses = 0
        self.write_hits = 0
        self.write_misses = 0
        self.refill_beats = 0
        self.evictions = 0

    # -- lookup ------------------------------------------------------------
    def _index(self, addr):
        return (addr // self.line_bytes) % self.sets

    def _tag(self, addr):
        return addr // (self.line_bytes * self.sets)

    def _find(self, addr):
        for w in self.tags[self._index(addr)]:
            if w.valid and w.tag == self._tag(addr):
                return w
        return None

    def _allocate(self, addr):
        """Read allocate, least-recently-used way."""
        s = self.tags[self._index(addr)]
        victim = None
        for w in s:
            if not w.valid:
                victim = w
                break
        if victim is None:
            victim = min(s, key=lambda w: w.used)
            self.evictions += 1
        base = (addr // self.line_bytes) * self.line_bytes
        # A failed refill never validates a partial line; there is no failure
        # path in this memory, so the line is filled whole or not at all.
        victim.data = self.mem.read(base, self.line_bytes)
        victim.tag = self._tag(addr)
        victim.valid = True
        self.refill_beats += self.beats
        return victim

    # -- phases -------------------------------------------------------------
    def _ripe(self, bus):
        """The access completing this cycle, if any.  Pure: one response port,
        ordered, so the oldest ready entry wins and nothing is mutated."""
        ready = [t for t in self.pipe if t[0] <= bus.cycle]
        if not ready:
            return None
        return min(ready, key=lambda t: (t[0], t[1].tag))

    def _data_for(self, r):
        """The bytes this access returns.  A resident line answers from the
        array; a line still being filled answers from memory, which is where
        the refill was going to get them anyway -- the cycles were already
        charged when the miss was accepted."""
        line = self._find(r.addr)
        base = (r.addr // self.line_bytes) * self.line_bytes
        off = r.addr - base
        if line is not None:
            return line.data[off:off + r.size]
        return self.mem.read(r.addr, r.size)

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_READY, False)
            bus.pub(self.S_RESP, None)
            return
        bus.pub(self.S_READY, len(self.pipe) < self.depth)
        t = self._ripe(bus)
        bus.pub(self.S_RESP,
                None if t is None else MemResp(t[1].tag, t[1].addr,
                                               self._data_for(t[1])))

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            return
        self.clock += 1
        t = self._ripe(bus)
        if t is not None:
            self.pipe.remove(t)
            r = t[1]
            # Read allocate happens here, not in settle: filling a way is a
            # state change and settle runs several times a cycle.
            line = self._find(r.addr)
            if line is None:
                line = self._allocate(r.addr)
            line.used = self.clock

        for st in (bus.get(self.S_ST) or ()) if self.S_ST is not None else ():
            # Write through, no write allocate: the bytes are already in memory
            # (retirement put them there); update the array only if resident.
            line = self._find(st[0])
            if line is not None:
                base = (st[0] // self.line_bytes) * self.line_bytes
                off = st[0] - base
                d = bytearray(line.data)
                d[off:off + len(st[1])] = st[1]
                line.data = bytes(d)
                line.used = self.clock
                self.write_hits += 1
            else:
                self.write_misses += 1

        req = bus.get(self.S_REQ)
        if req is not None and len(self.pipe) < self.depth:
            line = self._find(req.addr)
            if line is not None:
                line.used = self.clock
                self.hits += 1
                lat, hit = self.hit_latency, True
            else:
                self.misses += 1
                lat, hit = self.hit_latency + self.beats * self.beat_cycles, False
            self.pipe.append((bus.cycle + max(1, lat), req, hit))

    def report(self):
        n = self.hits + self.misses
        return {"reads": n, "hits": self.hits, "misses": self.misses,
                "hit_rate": round(self.hits / float(n), 4) if n else None,
                "write_hits": self.write_hits,
                "write_misses": self.write_misses,
                "refill_beats": self.refill_beats, "evictions": self.evictions,
                "geometry": "%dB %dway %dB-line" %
                            (self.sets * self.ways * self.line_bytes,
                             self.ways, self.line_bytes)}
