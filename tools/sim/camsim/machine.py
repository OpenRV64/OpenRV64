"""Assemble the executing machine, and run a program on it.

    fetch --mtl.ireq--> MTL --> physical memory --mtl.iresp--> fetch
      |  core.cands
      v
    issue --issue.exu--> EXU --exu.result--.
      |   --issue.lsu--> LSU --mtl.dreq--> MTL --> memory
      |                                            |
      `------------------ ROB <--------------------'
                           |  dispatch.sched (mispredict)
                           v
                        Resolve --redirect--> fetch, issue, exu, lsu

The MTL sits between every unit and memory, which is what makes Sv39 a
property of the machine rather than of each unit.
"""

from .bus import Bus
from .modules.clock import Clock
from .modules.memory import PhysMem
from .modules.mtl import Mtl, Pmp, SATP_MODE_SV39, PRIV_M, PRIV_S
from .modules.l1 import L1
from .modules.core import IFetch, Issue, Exu, Lsu, Rob, RegFile
from .modules.resolve import Resolve
from .modules import rv64 as R


def build(mem, entry_pc, fetch_width=3, issue_width=2, exu_pipes=2,
          lsu_depth=8, lsu_ports=1, rob_depth=16, retire_width=2,
          mem_latency=0,
          phys_regs=63, window=32,
          itlb=16, dtlb=16, walk_latency=3, pmp_ranges=None, timing=True,
          priv=PRIV_M, satp=0, predict="bp8",
          l1_bytes=16 * 1024, l1_ways=4, line_bytes=64, l1_hit=2,
          beat_cycles=1):
    regs = RegFile()
    from .modules.bp import make as make_bp
    bp = None if predict == "seq" else make_bp(predict)
    bus = Bus(timing=timing)
    bus.add(Clock(reset_steps=1).port())
    # A TLB hit costs nothing on its own: the L1 is virtually indexed and
    # physically tagged, so the set lookup runs against the page offset while
    # translation produces the tag.  Only a walk adds time.  Charging for the
    # translation *and* the cache access in series is the mistake that made a
    # load-to-use look like seven cycles.
    mtl = bus.add(Mtl(mem, itlb=itlb, dtlb=dtlb, walk_latency=walk_latency,
                      hit_latency=mem_latency, pmp=Pmp(pmp_ranges)))
    # Separate L1I and L1D, as the RTL has: the two sides are independent
    # paths below the MTL, not one port they take turns on.
    l1i = bus.add(L1(mem, "l1i.req", "l1i.resp", "l1i.ready", "l1i",
                     cache_bytes=l1_bytes, line_bytes=line_bytes,
                     ways=l1_ways, hit_latency=l1_hit,
                     beat_cycles=beat_cycles, takes_stores=False))
    l1d = bus.add(L1(mem, "l1d.req", "l1d.resp", "l1d.ready", "l1d",
                     cache_bytes=l1_bytes, line_bytes=line_bytes,
                     ways=l1_ways, hit_latency=l1_hit,
                     beat_cycles=beat_cycles))
    fe = bus.add(IFetch(entry_pc=entry_pc, width=fetch_width,
                        predict=predict, predictor=bp))
    rob = Rob(regs, mem, depth=rob_depth, retire_width=retire_width,
              predictor=bp)
    # The machine can be started already in supervisor mode with SATP loaded,
    # which is what a boot stub would have left behind.  M-mode is Bare, so a
    # test that never leaves it never translates.
    rob.boot_priv, rob.boot_satp = priv, satp
    rob.priv, rob.satp = priv, satp
    bus.add(Issue(regs, rob, width=issue_width, phys_regs=phys_regs,
                  window=window))
    bus.add(Exu(pipes=exu_pipes))
    bus.add(Lsu(depth=lsu_depth, ports=lsu_ports))
    bus.add(rob)
    bus.add(Resolve())
    return {"bus": bus, "mem": mem, "regs": regs, "mtl": mtl, "bp": bp,
            "fetch": fe, "rob": rob, "l1i": l1i, "l1d": l1d}


def run(m, max_cycles=100000):
    bus = m["bus"]
    rob = m["rob"]
    bus.elaborate()
    priv0, satp0 = rob.priv, rob.satp
    bus.run(until=lambda b: b.cycle >= max_cycles or rob.halt is not None)
    rep = bus.finish()
    return {"cycles": bus.cycle - 1, "halt": rob.halt, "retired": rob.retired,
            "report": rep}


# --------------------------------------------------------------------------
# A very small assembler, so a test program is readable in the file that uses
# it rather than a wall of hex.
# --------------------------------------------------------------------------

X = dict(("x%d" % i, i) for i in range(32))
X.update({"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6,
          "t2": 7, "s0": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13,
          "a4": 14, "a5": 15, "a6": 16, "a7": 17,
          "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23,
          "s8": 24, "s9": 25, "s10": 26, "s11": 27,
          "t3": 28, "t4": 29, "t5": 30, "t6": 31})


def _r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(imm, rs2, rs1, f3, op):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
        (f3 << 12) | ((imm & 0x1F) << 7) | op


def _b(imm, rs2, rs1, f3, op):
    return ((((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) |
            (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
            ((((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7)) | op)


def _u(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op


def _j(imm, rd, op):
    return ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) |
            (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) |
            (rd << 7) | op)


def asm(lines, base=0):
    """Assemble a tiny subset.  Labels are `name:`; branches take labels."""
    labels, prog = {}, []
    for ln in lines:
        t = ln.split("#")[0].strip()
        if not t:
            continue
        if t.endswith(":"):
            labels[t[:-1]] = base + 4 * len(prog)
            continue
        prog.append(t)
    words = []
    for n, t in enumerate(prog):
        pc = base + 4 * n
        parts = t.replace(",", " ").split()
        op, a = parts[0], parts[1:]
        g = lambda k: X[a[k]]
        v = lambda k: labels[a[k]] if a[k] in labels else int(a[k], 0)
        if op == "addi":
            w = _i(v(2), g(1), 0, g(0), R.OP_IMM)
        elif op == "andi":
            w = _i(v(2), g(1), 7, g(0), R.OP_IMM)
        elif op == "ori":
            w = _i(v(2), g(1), 6, g(0), R.OP_IMM)
        elif op == "slli":
            w = _i(v(2), g(1), 1, g(0), R.OP_IMM)
        elif op == "srli":
            w = _i(v(2), g(1), 5, g(0), R.OP_IMM)
        elif op == "add":
            w = _r(0, g(2), g(1), 0, g(0), R.OP_REG)
        elif op == "sub":
            w = _r(0x20, g(2), g(1), 0, g(0), R.OP_REG)
        elif op == "mul":
            w = _r(1, g(2), g(1), 0, g(0), R.OP_REG)
        elif op == "div":
            w = _r(1, g(2), g(1), 4, g(0), R.OP_REG)
        elif op == "rem":
            w = _r(1, g(2), g(1), 6, g(0), R.OP_REG)
        elif op == "xor":
            w = _r(0, g(2), g(1), 4, g(0), R.OP_REG)
        elif op == "lui":
            w = _u(v(1), g(0), R.OP_LUI)
        elif op == "ld":
            w = _i(v(2), g(1), 3, g(0), R.OP_LOAD)
        elif op == "lw":
            w = _i(v(2), g(1), 2, g(0), R.OP_LOAD)
        elif op == "lbu":
            w = _i(v(2), g(1), 4, g(0), R.OP_LOAD)
        elif op == "sd":
            w = _s(v(2), g(0), g(1), 3, R.OP_STORE)
        elif op == "sw":
            w = _s(v(2), g(0), g(1), 2, R.OP_STORE)
        elif op in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            f3 = {"beq": 0, "bne": 1, "blt": 4, "bge": 5,
                  "bltu": 6, "bgeu": 7}[op]
            w = _b(v(2) - pc, g(1), g(0), f3, R.OP_BRANCH)
        elif op == "jal":
            w = _j(v(1) - pc, g(0), R.OP_JAL)
        elif op == "jalr":
            w = _i(v(2), g(1), 0, g(0), R.OP_JALR)
        elif op == "csrrw":
            w = _i(int(a[2], 0), g(1), 1, g(0), R.OP_SYSTEM)
        elif op == "sfence":
            w = (0x09 << 25) | R.OP_SYSTEM
        elif op == "ecall":
            w = R.OP_SYSTEM
        elif op == "nop":
            w = _i(0, 0, 0, 0, R.OP_IMM)
        else:
            raise ValueError("unassembled: %s" % t)
        words.append(w)
    return words, labels


def load_program(mem, base, words):
    blob = bytearray()
    for w in words:
        blob += (w & 0xFFFFFFFF).to_bytes(4, "little")
    mem.load(base, bytes(blob))
    return base + len(blob)


class Sv39(object):
    """Build page tables in physical memory, one mapping at a time.

    Tables are allocated on demand and cached by their index path, so two
    mappings that share a 1G or 2M region share the table that covers it.
    Doing this by hand is how a test ends up with its second mapping quietly
    orphaning the first's leaf table -- the walk is correct either way, and
    the fault it produces looks like a model bug."""

    RWX = 0xCF        # V R W X A D
    RW = 0xC7         # V R W   A D
    RX = 0xCB         # V R   X A D
    RO = 0xC3         # V R     A D

    def __init__(self, mem, table_base, table_pages=32):
        self.mem = mem
        self.root = table_base
        self._next = table_base + 0x1000
        self._limit = table_base + table_pages * 0x1000
        self._tables = {}
        self.mem.load(table_base, b"\x00" * 0x1000)

    def _alloc(self):
        if self._next >= self._limit:
            raise RuntimeError("Sv39: out of page-table space")
        a, self._next = self._next, self._next + 0x1000
        self.mem.load(a, b"\x00" * 0x1000)
        return a

    @staticmethod
    def _pte(pa, flags):
        return ((pa >> 12) << 10) | flags

    def _descend(self, table, index, path):
        key = path + (index,)
        nxt = self._tables.get(key)
        if nxt is None:
            nxt = self._alloc()
            self._tables[key] = nxt
            self.mem.put_u64(table + index * 8, self._pte(nxt, 0x1))
        return nxt

    def map(self, va, pa, pages=1, flags=RWX, page_size=0x1000):
        """Map `pages` pages of `page_size` (4K or 2M) from va to pa."""
        for i in range(pages):
            v, p = va + i * page_size, pa + i * page_size
            v2, v1, v0 = (v >> 30) & 0x1FF, (v >> 21) & 0x1FF, (v >> 12) & 0x1FF
            l1 = self._descend(self.root, v2, ())
            if page_size == 0x200000:
                self.mem.put_u64(l1 + v1 * 8, self._pte(p, flags))
                continue
            l0 = self._descend(l1, v1, (v2,))
            self.mem.put_u64(l0 + v0 * 8, self._pte(p, flags))
        return self

    def satp(self):
        return (SATP_MODE_SV39 << 60) | (self.root >> 12)


def load_elf(mem, path, physical=True):
    """Place an ELF64 little-endian image's PT_LOAD segments into memory.

    Same rule as ``tools/elf2mem.py``: load segments, not objcopy output, so
    sparse VMAs and zero-filled BSS survive.  Returns the entry PC.

    Loads at each segment's **physical** address by default.  An image with an
    Sv39 loader is linked ``.text 0x40001000 : AT(0x80001000)`` -- it runs at
    the virtual address but has to be *placed* at the physical one, and using
    p_vaddr puts the payload where the machine will never look."""
    import struct
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:4] != b"\x7fELF" or blob[4] != 2 or blob[5] != 1:
        raise ValueError("%s is not a little-endian ELF64" % path)
    entry = struct.unpack_from("<Q", blob, 24)[0]
    phoff = struct.unpack_from("<Q", blob, 32)[0]
    phentsize = struct.unpack_from("<H", blob, 54)[0]
    phnum = struct.unpack_from("<H", blob, 56)[0]
    loaded = 0
    for i in range(phnum):
        off = phoff + i * phentsize
        p_type = struct.unpack_from("<I", blob, off)[0]
        if p_type != 1:                      # PT_LOAD
            continue
        p_offset = struct.unpack_from("<Q", blob, off + 8)[0]
        p_vaddr = struct.unpack_from("<Q", blob, off + 16)[0]
        p_paddr = struct.unpack_from("<Q", blob, off + 24)[0]
        p_filesz = struct.unpack_from("<Q", blob, off + 32)[0]
        p_memsz = struct.unpack_from("<Q", blob, off + 40)[0]
        at = p_paddr if (physical and p_paddr) else p_vaddr
        mem.load(at, blob[p_offset:p_offset + p_filesz])
        if p_memsz > p_filesz:               # .bss
            mem.load(at + p_filesz, b"\x00" * (p_memsz - p_filesz))
        loaded += p_memsz
    return entry, loaded


def elf_symbols(path):
    """name -> address, for checking a result the program left in memory."""
    import struct
    with open(path, "rb") as f:
        blob = f.read()
    shoff = struct.unpack_from("<Q", blob, 40)[0]
    shentsize = struct.unpack_from("<H", blob, 58)[0]
    shnum = struct.unpack_from("<H", blob, 60)[0]
    syms = {}
    for i in range(shnum):
        off = shoff + i * shentsize
        sh_type = struct.unpack_from("<I", blob, off + 4)[0]
        if sh_type != 2:                     # SHT_SYMTAB
            continue
        sh_offset = struct.unpack_from("<Q", blob, off + 24)[0]
        sh_size = struct.unpack_from("<Q", blob, off + 32)[0]
        sh_link = struct.unpack_from("<I", blob, off + 40)[0]
        sh_entsize = struct.unpack_from("<Q", blob, off + 56)[0]
        str_off = struct.unpack_from("<Q", blob, shoff + sh_link * shentsize + 24)[0]
        for j in range(sh_size // sh_entsize):
            e = sh_offset + j * sh_entsize
            nameoff = struct.unpack_from("<I", blob, e)[0]
            value = struct.unpack_from("<Q", blob, e + 8)[0]
            end = blob.index(b"\x00", str_off + nameoff)
            nm = blob[str_off + nameoff:end].decode("ascii", "replace")
            if nm:
                syms[nm] = value
    return syms
