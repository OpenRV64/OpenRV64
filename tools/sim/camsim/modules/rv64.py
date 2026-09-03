"""RV64IM execution semantics.

casim never needed these -- it replays a golden, so an instruction's result is
whatever the trace said it was.  Executing needs the real thing, so this is
new code rather than a port, and it is deliberately one pure function per
instruction class with no machine state of its own: the units call it, and
where the result goes is their business.

Covers RV64I, RV64M, and enough of Zicsr/privileged to start and stop: CSR
read/write, ECALL, EBREAK, MRET/SRET, FENCE, WFI.  Not covered: A, F, D, C.
An unimplemented encoding raises ILLEGAL rather than quietly computing zero,
because a model that invents results is worse than one that stops.
"""

MASK = 0xFFFFFFFFFFFFFFFF
M32 = 0xFFFFFFFF

# instruction classes, matching casim.stream
ALU, LOAD, STORE, BRANCH, JUMP, MULDIV, SYSTEM = range(7)

OP_LOAD, OP_MISC_MEM, OP_IMM, OP_AUIPC, OP_IMM32 = 0x03, 0x0F, 0x13, 0x17, 0x1B
OP_STORE, OP_REG, OP_LUI, OP_REG32 = 0x23, 0x33, 0x37, 0x3B
OP_BRANCH, OP_JALR, OP_JAL, OP_SYSTEM = 0x63, 0x67, 0x6F, 0x73

# trap causes
CAUSE_ILLEGAL = 2
CAUSE_BREAKPOINT = 3
CAUSE_LOAD_MISALIGNED = 4
CAUSE_STORE_MISALIGNED = 6
CAUSE_ECALL_U, CAUSE_ECALL_S, CAUSE_ECALL_M = 8, 9, 11
CAUSE_IFETCH_PAGE_FAULT = 12
CAUSE_LOAD_PAGE_FAULT = 13
CAUSE_STORE_PAGE_FAULT = 15
CAUSE_IFETCH_ACCESS = 1
CAUSE_LOAD_ACCESS = 5
CAUSE_STORE_ACCESS = 7


class Illegal(Exception):
    def __init__(self, instr, pc):
        Exception.__init__(self, "illegal instruction %08x at %#x" % (instr, pc))
        self.instr = instr
        self.pc = pc


def sext(v, bits):
    m = 1 << (bits - 1)
    return ((v & ((1 << bits) - 1)) ^ m) - m


def s64(v):
    return sext(v, 64)


def opcode(i):
    return i & 0x7F


def rd(i):
    return (i >> 7) & 0x1F


def rs1(i):
    return (i >> 15) & 0x1F


def rs2(i):
    return (i >> 20) & 0x1F


def funct3(i):
    return (i >> 12) & 7


def funct7(i):
    return (i >> 25) & 0x7F


def imm_i(i):
    return sext(i >> 20, 12)


def imm_s(i):
    return sext(((i >> 25) << 5) | ((i >> 7) & 0x1F), 12)


def imm_b(i):
    v = (((i >> 31) & 1) << 12) | (((i >> 7) & 1) << 11) | \
        (((i >> 25) & 0x3F) << 5) | (((i >> 8) & 0xF) << 1)
    return sext(v, 13)


def imm_u(i):
    return sext(i & 0xFFFFF000, 32)


def imm_j(i):
    v = (((i >> 31) & 1) << 20) | (((i >> 12) & 0xFF) << 12) | \
        (((i >> 20) & 1) << 11) | (((i >> 21) & 0x3FF) << 1)
    return sext(v, 21)


LEGAL_OPCODES = frozenset((OP_LOAD, OP_MISC_MEM, OP_IMM, OP_AUIPC, OP_IMM32,
                           OP_STORE, OP_REG, OP_LUI, OP_REG32, OP_BRANCH,
                           OP_JALR, OP_JAL, OP_SYSTEM))


def is_legal(i):
    """Whether the encoding is one this model implements.

    Worth being strict about: an unrecognised opcode that falls through to
    "add" turns a jump into unmapped memory into thousands of retired
    instructions that compute nothing, and the failure then shows up somewhere
    else entirely.  A model that invents results is worse than one that stops."""
    return opcode(i) in LEGAL_OPCODES


def classify(i):
    op = opcode(i)
    if op == OP_LOAD:
        return LOAD
    if op == OP_STORE:
        return STORE
    if op == OP_BRANCH:
        return BRANCH
    if op in (OP_JAL, OP_JALR):
        return JUMP
    if op == OP_SYSTEM:
        return SYSTEM
    if op in (OP_REG, OP_REG32) and funct7(i) == 1:
        return MULDIV
    return ALU


def regs_used(i):
    """(rd, rs1, rs2, writes_rd, uses_rs1, uses_rs2) for the scoreboard."""
    op = opcode(i)
    if op in (OP_LUI, OP_AUIPC, OP_JAL):
        return (rd(i), 0, 0, rd(i) != 0, False, False)
    if op in (OP_JALR, OP_LOAD, OP_IMM, OP_IMM32):
        return (rd(i), rs1(i), 0, rd(i) != 0, True, False)
    if op == OP_STORE:
        return (0, rs1(i), rs2(i), False, True, True)
    if op == OP_BRANCH:
        return (0, rs1(i), rs2(i), False, True, True)
    if op in (OP_REG, OP_REG32):
        return (rd(i), rs1(i), rs2(i), rd(i) != 0, True, True)
    if op == OP_SYSTEM:
        csr_imm = funct3(i) in (5, 6, 7)
        return (rd(i), 0 if csr_imm else rs1(i), 0,
                rd(i) != 0, funct3(i) not in (0, 5, 6, 7), False)
    if op == OP_MISC_MEM:
        return (0, 0, 0, False, False, False)
    return (0, 0, 0, False, False, False)


def _mul_parts(a, b, signed_a, signed_b):
    x = s64(a) if signed_a else a
    y = s64(b) if signed_b else b
    return (x * y) >> 64 & MASK


def alu(i, a, b, pc):
    """Everything that produces a register value without touching memory.

    Returns the 64-bit result.  ``a``/``b`` are the raw register values."""
    op = opcode(i)
    if op not in LEGAL_OPCODES:
        raise Illegal(i, pc)
    f3, f7 = funct3(i), funct7(i)

    if op == OP_LUI:
        return imm_u(i) & MASK
    if op == OP_AUIPC:
        return (pc + imm_u(i)) & MASK
    if op == OP_JAL or op == OP_JALR:
        return (pc + 4) & MASK

    if op in (OP_IMM, OP_IMM32):
        b = imm_i(i) & MASK
        if op == OP_IMM32:
            f7 = (i >> 25) & 0x7F
    if op in (OP_REG, OP_REG32) and f7 == 1:
        return muldiv(i, a, b)

    w32 = op in (OP_IMM32, OP_REG32)
    if f3 == 0:                                  # ADD / SUB / ADDI
        sub = (op in (OP_REG, OP_REG32)) and (f7 == 0x20)
        r = (a - b) if sub else (a + b)
    elif f3 == 1:                                # SLL
        sh = b & (31 if w32 else 63)
        r = a << sh
    elif f3 == 2:                                # SLT
        return 1 if s64(a) < s64(b) else 0
    elif f3 == 3:                                # SLTU
        return 1 if (a & MASK) < (b & MASK) else 0
    elif f3 == 4:                                # XOR
        r = a ^ b
    elif f3 == 5:                                # SRL / SRA
        sh = b & (31 if w32 else 63)
        if w32:
            v = a & M32
            r = (sext(v, 32) >> sh) if (f7 & 0x20) else (v >> sh)
        else:
            r = (s64(a) >> sh) if (f7 & 0x20) else ((a & MASK) >> sh)
    elif f3 == 6:                                # OR
        r = a | b
    elif f3 == 7:                                # AND
        r = a & b
    else:
        raise Illegal(i, pc)
    if w32:
        return sext(r & M32, 32) & MASK
    return r & MASK


def muldiv(i, a, b):
    f3 = funct3(i)
    w32 = opcode(i) == OP_REG32
    if w32:
        x, y = sext(a & M32, 32), sext(b & M32, 32)
        if f3 == 0:
            r = x * y
        elif f3 == 4:                            # DIVW
            r = -1 if y == 0 else (abs(x) // abs(y)) * (1 if (x < 0) == (y < 0) else -1)
            if x == -(1 << 31) and y == -1:
                r = x
        elif f3 == 5:                            # DIVUW
            xa, ya = a & M32, b & M32
            r = M32 if ya == 0 else xa // ya
            r = sext(r & M32, 32)
        elif f3 == 6:                            # REMW
            r = x if y == 0 else (abs(x) % abs(y)) * (1 if x >= 0 else -1)
            if x == -(1 << 31) and y == -1:
                r = 0
        elif f3 == 7:                            # REMUW
            xa, ya = a & M32, b & M32
            r = sext(xa & M32, 32) if ya == 0 else xa % ya
        else:
            raise Illegal(i, 0)
        return sext(r & M32, 32) & MASK

    if f3 == 0:                                  # MUL
        return (s64(a) * s64(b)) & MASK
    if f3 == 1:                                  # MULH
        return _mul_parts(a, b, True, True)
    if f3 == 2:                                  # MULHSU
        return ((s64(a) * (b & MASK)) >> 64) & MASK
    if f3 == 3:                                  # MULHU
        return (((a & MASK) * (b & MASK)) >> 64) & MASK
    x, y = s64(a), s64(b)
    if f3 == 4:                                  # DIV
        if y == 0:
            return MASK
        if x == -(1 << 63) and y == -1:
            return x & MASK
        return ((abs(x) // abs(y)) * (1 if (x < 0) == (y < 0) else -1)) & MASK
    if f3 == 5:                                  # DIVU
        return MASK if (b & MASK) == 0 else ((a & MASK) // (b & MASK)) & MASK
    if f3 == 6:                                  # REM
        if y == 0:
            return x & MASK
        if x == -(1 << 63) and y == -1:
            return 0
        return ((abs(x) % abs(y)) * (1 if x >= 0 else -1)) & MASK
    if f3 == 7:                                  # REMU
        return (a & MASK) if (b & MASK) == 0 else ((a & MASK) % (b & MASK)) & MASK
    raise Illegal(i, 0)


def branch_taken(i, a, b):
    f3 = funct3(i)
    if f3 == 0:
        return a == b
    if f3 == 1:
        return a != b
    if f3 == 4:
        return s64(a) < s64(b)
    if f3 == 5:
        return s64(a) >= s64(b)
    if f3 == 6:
        return (a & MASK) < (b & MASK)
    if f3 == 7:
        return (a & MASK) >= (b & MASK)
    raise Illegal(i, 0)


def next_pc(i, pc, a, b):
    """The architectural next PC.  This is what a branch unit resolves."""
    op = opcode(i)
    if op == OP_JAL:
        return (pc + imm_j(i)) & MASK
    if op == OP_JALR:
        return (a + imm_i(i)) & ~1 & MASK
    if op == OP_BRANCH:
        return (pc + imm_b(i)) & MASK if branch_taken(i, a, b) else (pc + 4) & MASK
    return (pc + 4) & MASK


LOAD_SIZE = {0: 1, 1: 2, 2: 4, 3: 8, 4: 1, 5: 2, 6: 4}
STORE_SIZE = {0: 1, 1: 2, 2: 4, 3: 8}


def load_result(i, raw):
    """Sign- or zero-extend a loaded value per funct3."""
    f3 = funct3(i)
    n = LOAD_SIZE[f3]
    v = int.from_bytes(raw[:n], "little")
    if f3 in (0, 1, 2):
        return sext(v, n * 8) & MASK
    return v & MASK
