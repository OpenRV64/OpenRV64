"""Physical memory, and the SRAM ports onto it.

One backing store, several ports.  That is the honest shape: the I-side and
the D-side and the page-table walker are looking at the same physical memory,
and a model where they each had their own could not run a page table at all --
the walker writes nothing, but it has to read what the loader wrote and what a
store may since have changed.

``Sram`` is deliberately simple: a fixed access latency, one request in flight,
no cache, no bursts.  The cache hierarchy is out of scope here exactly as it is
in casim, and the point of this unit is to be a truthful *interface* -- request
in, response N cycles later, backpressure when busy -- so that a real L1 can
replace it without anything upstream noticing.
"""

import struct

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE

_MASK = 0xFFFFFFFFFFFFFFFF


class PhysMem(object):
    """Sparse physical memory, page-granular, little-endian."""

    PAGE = 0x1000

    def __init__(self, page_bytes=None):
        self.page_bytes = page_bytes or self.PAGE
        self.pages = {}
        self.reads = 0
        self.writes = 0

    # -- backing store -----------------------------------------------------
    def _page(self, addr):
        key = addr // self.page_bytes
        p = self.pages.get(key)
        if p is None:
            p = bytearray(self.page_bytes)
            self.pages[key] = p
        return p, addr % self.page_bytes

    def load(self, addr, data):
        """Place bytes at a physical address, growing pages as needed."""
        for i in range(0, len(data), 64):
            chunk = data[i:i + 64]
            a = addr + i
            for j, b in enumerate(chunk):
                p, off = self._page(a + j)
                p[off] = b if isinstance(b, int) else ord(b)

    def read(self, addr, size):
        self.reads += 1
        out_ = bytearray(size)
        for i in range(size):
            p, off = self._page(addr + i)
            out_[i] = p[off]
        return bytes(out_)

    def write(self, addr, data):
        self.writes += 1
        for i, b in enumerate(data):
            p, off = self._page(addr + i)
            p[off] = b

    # -- convenience -------------------------------------------------------
    def u64(self, addr):
        return struct.unpack("<Q", self.read(addr, 8))[0]

    def put_u64(self, addr, value):
        self.write(addr, struct.pack("<Q", value & _MASK))

    def u32(self, addr):
        return struct.unpack("<I", self.read(addr, 4))[0]

    def put_u32(self, addr, value):
        self.write(addr, struct.pack("<I", value & 0xFFFFFFFF))

    def span(self):
        if not self.pages:
            return (0, 0)
        ks = sorted(self.pages)
        return (ks[0] * self.page_bytes, (ks[-1] + 1) * self.page_bytes)


class MemReq(object):
    """A physical access.  ``write`` carries bytes; a read carries a size."""

    __slots__ = ("tag", "addr", "size", "write", "data")

    def __init__(self, tag, addr, size, write=None, data=None):
        self.tag = tag
        self.addr = addr
        self.size = size
        self.write = write
        self.data = data

    def __eq__(self, o):
        return isinstance(o, MemReq) and o.tag == self.tag

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return hash(self.tag)

    def __repr__(self):
        return "%s%s@%x" % ("st" if self.write else "ld", self.tag, self.addr)


class MemResp(object):
    __slots__ = ("tag", "addr", "data")

    def __init__(self, tag, addr, data):
        self.tag = tag
        self.addr = addr
        self.data = data

    def __eq__(self, o):
        return isinstance(o, MemResp) and o.tag == self.tag

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return hash(self.tag)

    def __repr__(self):
        return "resp%s@%x" % (self.tag, self.addr)


class Sram(Module):
    """One port onto physical memory: request in, response ``latency`` later.

    Signal names are constructor-supplied so the same unit can be the I-side,
    the D-side or the walker's port without a line of it changing."""

    def __init__(self, mem, req="mem.req", resp="mem.resp", ready="mem.ready",
                 latency=2, name=None):
        self.mem = mem
        self.latency = latency
        self._req, self._resp, self._ready = req, resp, ready
        self.publishes = [
            out(resp, REG, PULSE, None, doc="completed access"),
            out(ready, ASYNC, LEVEL, True, doc="can accept a request"),
        ]
        self.subscribes = [req]
        Module.__init__(self, name or ("sram_" + req.split(".")[0]))

    def build(self, bus):
        self.S_REQ = bus.signal(self._req)
        self.S_RESP = bus.signal(self._resp)
        self.S_READY = bus.signal(self._ready)
        self._reset_state()

    def _reset_state(self):
        self.busy = []          # [(ready_cycle, MemReq)]
        self.served = 0
        self.max_outstanding = 0

    def settle(self, bus):
        # One access at a time: an SRAM with a fixed latency and no banking.
        bus.pub(self.S_READY, not self.busy and not bus.resetting())

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            return
        done = [r for c, r in self.busy if c <= bus.cycle]
        self.busy = [(c, r) for c, r in self.busy if c > bus.cycle]
        for r in done:
            if r.write:
                self.mem.write(r.addr, r.data)
                bus.pub(self.S_RESP, MemResp(r.tag, r.addr, None))
            else:
                bus.pub(self.S_RESP, MemResp(r.tag, r.addr,
                                             self.mem.read(r.addr, r.size)))
            self.served += 1
        req = bus.get(self.S_REQ)
        if req is not None and not self.busy:
            self.busy.append((bus.cycle + max(1, self.latency), req))
            self.max_outstanding = max(self.max_outstanding, len(self.busy))

    def report(self):
        return {"served": self.served, "latency": self.latency}
