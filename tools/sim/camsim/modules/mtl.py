"""MTL: the memory transaction layer.

Modelled on ``rtl/core/mtl``, the architectural memory-policy boundary: it owns
Bare/Sv39 translation, the side-local lookasides, the blocking page-table
walker, post-translation PMP, and admission of *physical* transactions into
L1I and L1D.  Everything above it speaks virtual addresses; everything below it
speaks physical ones.  Putting a page walk in two places is how the two sides
end up disagreeing about a page.

Invariants from the RTL's README, kept:

  * PMP is checked **after** translation and before a physical launch.
  * A denial completes locally as an access fault and emits no physical
    request.
  * PTE reads are physical reads with their own PMP check.
  * Page faults and access faults stay distinct through completion.
  * A SATP write flushes the micro-TLBs, which carry no ASID.

**A TLB hit is a pass-through, not a stage.**  The L1 is virtually indexed and
physically tagged, so the TLB runs beside the set lookup rather than in front
of it: on a hit the request reaches the cache in the cycle it arrives and the
answer goes back up in the cycle it returns.  Registering either direction
would add a cycle to every load and make the MTL a pipeline stage the hardware
does not have.  Only a walk costs time.  That makes fetch/LSU/MTL/L1 one
same-cycle region -- which is what it is in silicon, the L1 hit path being the
critical path.

**Two independent pipelines, one per side.**  L1I and L1D are separate caches
below this boundary; one shared transaction here serialises instruction supply
against every load.  Only the walker is shared, as the RTL's single PTW is.

Not modelled: the shared L2 TLB, cache arrays (see ``l1.py``), prefetch.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE
from .memory import MemReq

_MASK = 0xFFFFFFFFFFFFFFFF

ACCESS_READ, ACCESS_WRITE, ACCESS_EXEC = 0, 1, 2
PRIV_U, PRIV_S, PRIV_M = 0, 1, 3

PAGE_SHIFT = 12
LEVELS = 3
VPN_BITS = 9
PTE_SIZE = 8
PTE_V, PTE_R, PTE_W, PTE_X, PTE_U, PTE_G, PTE_A, PTE_D = (
    1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5, 1 << 6, 1 << 7)

SATP_MODE_BARE = 0
SATP_MODE_SV39 = 8

FAULT_NONE, FAULT_PAGE, FAULT_ACCESS = 0, 1, 2
FAULT_NAMES = {FAULT_NONE: "none", FAULT_PAGE: "page-fault",
               FAULT_ACCESS: "access-fault"}


def satp_mode(satp):
    return (satp >> 60) & 0xF


def satp_ppn(satp):
    return satp & ((1 << 44) - 1)


def vpn(va, level):
    return (va >> (PAGE_SHIFT + VPN_BITS * level)) & ((1 << VPN_BITS) - 1)


class Xlate(object):
    """A translation request from a side of the machine."""

    __slots__ = ("tag", "vaddr", "size", "access", "write_data", "side")

    def __init__(self, tag, vaddr, size, access, write_data=None, side="d"):
        self.tag = tag
        self.vaddr = vaddr
        self.size = size
        self.access = access
        self.write_data = write_data
        self.side = side

    def __eq__(self, o):
        return isinstance(o, Xlate) and o.tag == self.tag and o.side == self.side

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return hash((self.side, self.tag))

    def __repr__(self):
        return "%s%s@%x" % (self.side, self.tag, self.vaddr)


class XlateResp(object):
    __slots__ = ("tag", "vaddr", "paddr", "data", "fault", "side")

    def __init__(self, tag, vaddr, paddr, data, fault, side):
        self.tag = tag
        self.vaddr = vaddr
        self.paddr = paddr
        self.data = data
        self.fault = fault
        self.side = side

    def __eq__(self, o):
        return isinstance(o, XlateResp) and o.tag == self.tag \
            and o.side == self.side

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return hash((self.side, self.tag))

    def __repr__(self):
        return "%s%s@%x->%s%s" % (
            self.side, self.tag, self.vaddr,
            "x" if self.paddr is None else "%x" % self.paddr,
            "" if not self.fault else "!" + FAULT_NAMES[self.fault])


class MicroTlb(object):
    """``micro_tlb.v``: current address space only, flushed on SATP because it
    carries no ASID."""

    def __init__(self, entries=16):
        self.entries = entries
        self.tags = {}
        self.order = []
        self.hits = 0
        self.misses = 0
        self.flushes = 0

    def flush(self):
        self.tags.clear()
        del self.order[:]
        self.flushes += 1

    def probe(self, va):
        """Lookup with no bookkeeping, for use from a pure function."""
        page = va >> PAGE_SHIFT
        for lvl in range(LEVELS):
            e = self.tags.get((page >> (VPN_BITS * lvl), lvl))
            if e is not None:
                return e
        return None

    def lookup(self, va):
        e = self.probe(va)
        if e is None:
            self.misses += 1
        else:
            self.hits += 1
        return e

    def fill(self, va, ppn, level, flags):
        key = (va >> (PAGE_SHIFT + VPN_BITS * level), level)
        if key not in self.tags:
            if len(self.order) >= self.entries:
                self.tags.pop(self.order.pop(0), None)
            self.order.append(key)
        self.tags[key] = (ppn, level, flags)

    def stats(self):
        n = self.hits + self.misses
        return {"hits": self.hits, "misses": self.misses,
                "hit_rate": round(self.hits / float(n), 4) if n else None,
                "flushes": self.flushes}


class PageScreen(object):
    """``mtl.v``'s page screen: a tiny PLRU cache of *recent pages*, one per
    side, checked in the accept path.

    ``ENABLE_FETCH_PAGE_SCREEN`` / ``ENABLE_LSU_PAGE_SCREEN`` with four entries
    each in the RTL.  A hit lets the request be accepted **and launched in the
    same cycle** (``xlate_request_fire && lsu_page_hit_r``) and lets the
    cache's answer bypass the normal response path
    (``fetch_page_screen_resp_bypass``).  It is not a second TLB: it is small
    enough to sit in the accept path at all, which is the whole point -- a
    16-entry micro-TLB cannot, and that is why the fast path is gated on the
    screen rather than on any translation hit.

    Four entries sounds too few to matter until you notice what it is caching:
    pages, not addresses.  A loop touching code, stack and one array is three
    pages, and it stays hot indefinitely."""

    def __init__(self, entries=4):
        self.entries = entries
        self.slots = []          # [(vpn, ppn, flags, level)], most recent last
        self.hits = 0
        self.misses = 0
        self.flushes = 0

    def flush(self):
        del self.slots[:]
        self.flushes += 1

    def probe(self, va):
        """Pure: no PLRU update, so a settling function may call it freely."""
        vpn_ = va >> PAGE_SHIFT
        for (v, ppn, flags, level) in self.slots:
            if level == 0:
                if v == vpn_:
                    return (ppn, level, flags)
            elif (v >> (VPN_BITS * level)) == (vpn_ >> (VPN_BITS * level)):
                return (ppn, level, flags)
        return None

    def touch(self, va, ppn, level, flags):
        """PLRU update, at the edge."""
        vpn_ = va >> PAGE_SHIFT
        hit = self.probe(va)
        if hit is not None:
            self.hits += 1
            for i, e in enumerate(self.slots):
                if e[1] == hit[0] and e[3] == hit[1]:
                    self.slots.append(self.slots.pop(i))
                    break
            return
        self.misses += 1
        self.slots.append((vpn_, ppn, flags, level))
        del self.slots[:-self.entries]

    def stats(self):
        n = self.hits + self.misses
        return {"hits": self.hits, "misses": self.misses,
                "hit_rate": round(self.hits / float(n), 4) if n else None,
                "entries": self.entries}


class Pmp(object):
    """Post-translation physical checks.  Minimal by intent; what is kept is
    the invariant: after translation, and a denial emits no request."""

    def __init__(self, ranges=None):
        self.ranges = list(ranges or [])
        self.denials = 0

    def allows(self, paddr, access):
        if not self.ranges:
            return True
        for lo, hi in self.ranges:
            if lo <= paddr < hi:
                return True
        self.denials += 1
        return False


class Mtl(Module):
    name = "mtl"

    def __init__(self, mem, itlb=16, dtlb=16, walk_latency=3, hit_latency=0,
                 pmp=None, name=None, icache="l1i", dcache="l1d", depth=8,
                 passthrough=True, screen=4):
        self.mem = mem
        self.itlb = MicroTlb(itlb)
        self.dtlb = MicroTlb(dtlb)
        self.iscreen = PageScreen(screen)
        self.dscreen = PageScreen(screen)
        self.walk_latency = walk_latency
        self.hit_latency = hit_latency
        self.pmp = pmp or Pmp()
        self.depth = depth
        # The fast path, gated on a *screen* hit as the RTL gates it.
        self.passthrough = passthrough
        self._ic, self._dc = icache, dcache
        self.publishes = [
            # Registered.  Publishing the answer in the cycle the cache
            # returns it would save a cycle of load-to-use, but this module
            # and its consumer must then agree inside one settling round on
            # which access it belongs to -- and when they do not, the access
            # is retired here and stranded there.  See `passthrough`.
            out("mtl.iresp", REG, PULSE, None, doc="I-side result"),
            out("mtl.dresp", REG, PULSE, None, doc="D-side result"),
            out("mtl.iready", ASYNC, LEVEL, True),
            out("mtl.dready", ASYNC, LEVEL, True),
            out("mtl.walking", REG, LEVEL, False, doc="PTW busy"),
            out("mtl.iack", REG, PULSE, None, doc="I request accepted"),
            out("mtl.dack", REG, PULSE, None, doc="D request accepted"),
            out(icache + ".req", ASYNC, PULSE, None, doc="physical I access"),
            out(dcache + ".req", ASYNC, PULSE, None, doc="physical D access"),
        ]
        self.subscribes = ["mtl.ireq", "mtl.dreq", "csr.satp", "csr.priv",
                           "csr.sfence", icache + ".resp", dcache + ".resp",
                           icache + ".ready", dcache + ".ready"]
        Module.__init__(self, name)

    def build(self, bus):
        for a, n in (("S_IREQ", "mtl.ireq"), ("S_DREQ", "mtl.dreq"),
                     ("S_IRESP", "mtl.iresp"), ("S_DRESP", "mtl.dresp"),
                     ("S_IRDY", "mtl.iready"), ("S_DRDY", "mtl.dready"),
                     ("S_WALK", "mtl.walking"), ("S_IACK", "mtl.iack"),
                     ("S_DACK", "mtl.dack"), ("S_SATP", "csr.satp"),
                     ("S_PRIV", "csr.priv"), ("S_SFENCE", "csr.sfence"),
                     ("S_ICREQ", self._ic + ".req"),
                     ("S_DCREQ", self._dc + ".req"),
                     ("S_ICRESP", self._ic + ".resp"),
                     ("S_DCRESP", self._dc + ".resp"),
                     ("S_ICRDY", self._ic + ".ready"),
                     ("S_DCRDY", self._dc + ".ready")):
            setattr(self, a, bus.signal(n))
        self.SIDE = {
            "i": {"req": self.S_IREQ, "resp": self.S_IRESP, "ack": self.S_IACK,
                  "creq": self.S_ICREQ, "cresp": self.S_ICRESP,
                  "crdy": self.S_ICRDY, "rdy": self.S_IRDY},
            "d": {"req": self.S_DREQ, "resp": self.S_DRESP, "ack": self.S_DACK,
                  "creq": self.S_DCREQ, "cresp": self.S_DCRESP,
                  "crdy": self.S_DCRDY, "rdy": self.S_DRDY},
        }
        self._reset_state()

    def _reset_state(self):
        # Per side, in-flight translations that could not pass straight
        # through: walks, faults, and stores awaiting their local completion.
        self.slot = {"i": [], "d": []}
        # Launched straight into the cache without being recorded:
        # (side, tag) -> (Xlate, paddr).  Dropped when the answer comes back.
        self.passthru = {}
        self.walks = 0
        self.walk_steps = 0
        self.faults = {}
        self.served = 0
        self.hits_passed = 0
        self._last_satp = None

    # -- Sv39 ---------------------------------------------------------------
    def _mode(self, bus):
        satp = bus.get(self.S_SATP) or 0
        priv = bus.get(self.S_PRIV)
        return satp, (PRIV_M if priv is None else priv)

    def probe(self, va, access, satp, priv, sum_=False, mxr=False):
        """Translate from the TLB alone, with no fill and no counters.

        ``settle`` runs several times per cycle, so anything it mutated would
        be mutated several times -- a TLB filled on the strength of how often
        the bus happened to wake this module.  Returns ``(paddr, fault, miss)``
        where ``miss`` means "this needs the walker"."""
        mode = satp_mode(satp)
        if priv == PRIV_M or mode == SATP_MODE_BARE:
            return (va & _MASK, FAULT_NONE, False)
        if mode != SATP_MODE_SV39:
            return (None, FAULT_PAGE, True)
        if ((va >> 39) & 0x1FFFFFF) not in (0, 0x1FFFFFF):
            return (None, FAULT_PAGE, True)
        tlb = self.itlb if access == ACCESS_EXEC else self.dtlb
        e = tlb.probe(va)
        if e is None:
            return (None, FAULT_NONE, True)
        ppn, level, flags = e
        f = self._permit(flags, access, priv, sum_, mxr)
        if f:
            return (None, f, False)
        return (self._compose(ppn, level, va), FAULT_NONE, False)

    def translate(self, va, access, satp, priv, sum_=False, mxr=False):
        """Full translation, filling the TLB on a walk.  Called at the edge.

        Returns (paddr, fault, levels_walked)."""
        mode = satp_mode(satp)
        if priv == PRIV_M or mode == SATP_MODE_BARE:
            return (va & _MASK, FAULT_NONE, 0)
        if mode != SATP_MODE_SV39:
            return (None, FAULT_PAGE, 0)
        if ((va >> 39) & 0x1FFFFFF) not in (0, 0x1FFFFFF):
            return (None, FAULT_PAGE, 0)

        tlb = self.itlb if access == ACCESS_EXEC else self.dtlb
        hit = tlb.lookup(va)
        if hit is not None:
            ppn, level, flags = hit
            f = self._permit(flags, access, priv, sum_, mxr)
            if f:
                return (None, f, 0)
            return (self._compose(ppn, level, va), FAULT_NONE, 0)

        a = satp_ppn(satp) << PAGE_SHIFT
        steps = 0
        for level in range(LEVELS - 1, -1, -1):
            pte_addr = a + vpn(va, level) * PTE_SIZE
            steps += 1
            if not self.pmp.allows(pte_addr, ACCESS_READ):
                return (None, FAULT_ACCESS, steps)
            pte = self.mem.u64(pte_addr)
            if not (pte & PTE_V) or ((pte & PTE_W) and not (pte & PTE_R)):
                return (None, FAULT_PAGE, steps)
            if pte & (PTE_R | PTE_X):
                ppn = (pte >> 10) & ((1 << 44) - 1)
                if level and (ppn & ((1 << (VPN_BITS * level)) - 1)):
                    return (None, FAULT_PAGE, steps)   # misaligned superpage
                flags = pte & 0xFF
                f = self._permit(flags, access, priv, sum_, mxr)
                if f:
                    return (None, f, steps)
                tlb.fill(va, ppn, level, flags)
                return (self._compose(ppn, level, va), FAULT_NONE, steps)
            a = ((pte >> 10) & ((1 << 44) - 1)) << PAGE_SHIFT
        return (None, FAULT_PAGE, steps)

    @staticmethod
    def _compose(ppn, level, va):
        if level:
            keep = VPN_BITS * level
            low = (va >> PAGE_SHIFT) & ((1 << keep) - 1)
            ppn = (ppn & ~((1 << keep) - 1)) | low
        return ((ppn << PAGE_SHIFT) | (va & 0xFFF)) & _MASK

    @staticmethod
    def _permit(flags, access, priv, sum_, mxr):
        if access == ACCESS_EXEC and not (flags & PTE_X):
            return FAULT_PAGE
        if access == ACCESS_READ:
            if not ((flags & PTE_R) or (mxr and (flags & PTE_X))):
                return FAULT_PAGE
        if access == ACCESS_WRITE and not (flags & PTE_W):
            return FAULT_PAGE
        user = bool(flags & PTE_U)
        if priv == PRIV_U and not user:
            return FAULT_PAGE
        if priv == PRIV_S and user and not sum_:
            return FAULT_PAGE
        if not (flags & PTE_A):
            return FAULT_PAGE
        if access == ACCESS_WRITE and not (flags & PTE_D):
            return FAULT_PAGE
        return FAULT_NONE

    # -- pure helpers used by both phases ----------------------------------
    def _cache_request(self, bus, side):
        """The physical read to launch this cycle: a queued one first, then a
        newly arriving hit passing straight through."""
        s = self.SIDE[side]
        if not bus.get(s["crdy"]):
            return None
        for t in self.slot[side]:
            if (not t["sent"] and not t["fault"]
                    and t["x"].access != ACCESS_WRITE
                    and t["when"] <= bus.cycle):
                return MemReq(t["x"].tag, t["paddr"], t["x"].size, False, None)
        x = bus.get(s["req"])
        if x is None or len(self.slot[side]) >= self.depth:
            return None
        if x.access == ACCESS_WRITE:
            return None                       # retirement posts stores
        if any(t["x"].tag == x.tag for t in self.slot[side]):
            return None
        if (side, x.tag) in self.passthru:
            return None
        if not self.passthrough:
            return None
        satp, priv = self._mode(bus)
        paddr, fault = self._screen_probe(x.vaddr, x.access, satp, priv, side)
        if paddr is None or fault or not self.pmp.allows(paddr, x.access):
            return None            # not screened: costs the normal accept cycle
        return MemReq(x.tag, paddr, x.size, False, None)

    def _screen_probe(self, va, access, satp, priv, side):
        """Translate from the four-entry screen alone.  Pure.

        Bare mode screens trivially -- there is nothing to translate, so every
        access takes the fast path, which is also what the hardware does."""
        mode = satp_mode(satp)
        if priv == PRIV_M or mode == SATP_MODE_BARE:
            return (va & _MASK, FAULT_NONE)
        if mode != SATP_MODE_SV39:
            return (None, FAULT_PAGE)
        if ((va >> 39) & 0x1FFFFFF) not in (0, 0x1FFFFFF):
            return (None, FAULT_PAGE)
        sc = self.iscreen if side == "i" else self.dscreen
        e = sc.probe(va)
        if e is None:
            return (None, FAULT_NONE)
        ppn, level, flags = e
        f = self._permit(flags, access, priv, sum_=False, mxr=False)
        if f:
            return (None, f)
        return (self._compose(ppn, level, va), FAULT_NONE)

    def _completion(self, bus, side):
        """The response to publish this cycle, if any."""
        s = self.SIDE[side]
        r = bus.get(s["cresp"])
        if r is not None:
            for t in self.slot[side]:
                if t["sent"] and t["x"].tag == r.tag:
                    x = t["x"]
                    return XlateResp(x.tag, x.vaddr, t["paddr"], r.data,
                                     FAULT_NONE, side)
            p = self.passthru.get((side, r.tag))
            if p is not None:
                return XlateResp(p[0].tag, p[0].vaddr, p[1], r.data,
                                 FAULT_NONE, side)
        for t in self.slot[side]:
            x = t["x"]
            if t["fault"] and t["when"] <= bus.cycle:
                return XlateResp(x.tag, x.vaddr, None, None, t["fault"], side)
            if x.access == ACCESS_WRITE and t["when"] <= bus.cycle:
                return XlateResp(x.tag, x.vaddr, t["paddr"], None,
                                 FAULT_NONE, side)
        return None

    # -- phases -------------------------------------------------------------
    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_IRDY, False)
            bus.pub(self.S_DRDY, False)
            for sg in (self.S_ICREQ, self.S_DCREQ, self.S_IRESP, self.S_DRESP):
                bus.pub(sg, None)
            return
        bus.pub(self.S_IRDY, len(self.slot["i"]) < self.depth)
        bus.pub(self.S_DRDY, len(self.slot["d"]) < self.depth)
        for side in ("i", "d"):
            bus.pub(self.SIDE[side]["creq"], self._cache_request(bus, side))

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            self.itlb.flush()
            self.dtlb.flush()
            self.iscreen.flush()
            self.dscreen.flush()
            bus.pub(self.S_WALK, False)
            return

        satp, priv = self._mode(bus)
        if satp != self._last_satp:
            if self._last_satp is not None:
                self.itlb.flush()
                self.dtlb.flush()
                self.iscreen.flush()
                self.dscreen.flush()
            self._last_satp = satp
        if bus.get(self.S_SFENCE):
            self.itlb.flush()
            self.dtlb.flush()
            self.iscreen.flush()
            self.dscreen.flush()

        for side in ("i", "d"):
            s = self.SIDE[side]
            q = self.slot[side]

            done = self._completion(bus, side)
            if done is not None:
                bus.pub(s["resp"], done)
                self.served += 1
                if done.fault:
                    nm = FAULT_NAMES[done.fault]
                    self.faults[nm] = self.faults.get(nm, 0) + 1
                for t in list(q):
                    if t["x"].tag == done.tag:
                        q.remove(t)
                        break
                self.passthru.pop((side, done.tag), None)

            launched = bus.get(s["creq"])
            if launched is not None:
                for t in q:
                    if t["x"].tag == launched.tag:
                        t["sent"] = True
                        launched = None
                        break

            x = bus.get(s["req"])
            if x is None or len(q) >= self.depth:
                continue
            if any(t["x"].tag == x.tag for t in q) \
                    or (side, x.tag) in self.passthru:
                continue
            if launched is not None and launched.tag == x.tag:
                # Passed straight through on a TLB hit.  Nothing to record but
                # how to build the response when the cache answers.
                self.passthru[(side, x.tag)] = (x, launched.addr)
                self.hits_passed += 1
                bus.pub(s["ack"], x.tag)
                continue
            paddr, fault, steps = self.translate(x.vaddr, x.access, satp, priv)
            if steps:
                self.walks += 1
                self.walk_steps += steps
            self._screen_fill(x, satp, priv, side)
            if not fault and not self.pmp.allows(paddr, x.access):
                fault, paddr = FAULT_ACCESS, None
            q.append({"x": x, "paddr": paddr, "fault": fault, "sent": False,
                      "when": bus.cycle + self.hit_latency
                              + self.walk_latency * steps})
            bus.pub(s["ack"], x.tag)

        bus.pub(self.S_WALK,
                bool(self.slot["i"] or self.slot["d"] or self.passthru))

    def _screen_fill(self, x, satp, priv, side):
        """Bring the page this access touched into the screen, at the edge."""
        if priv == PRIV_M or satp_mode(satp) != SATP_MODE_SV39:
            return
        tlb = self.itlb if x.access == ACCESS_EXEC else self.dtlb
        e = tlb.probe(x.vaddr)
        if e is None:
            return
        ppn, level, flags = e
        (self.iscreen if side == "i" else self.dscreen).touch(
            x.vaddr, ppn, level, flags)

    def report(self):
        return {"served": self.served, "walks": self.walks,
                "walk_steps": self.walk_steps, "passed_through": self.hits_passed,
                "itlb": self.itlb.stats(), "dtlb": self.dtlb.stats(),
                "iscreen": self.iscreen.stats(), "dscreen": self.dscreen.stats(),
                "faults": self.faults, "pmp_denials": self.pmp.denials}
