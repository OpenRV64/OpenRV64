"""Minimal RV64 decode, sufficient to synthesise wrong-path work.

Correct-path instructions carry their class and register usage from the
golden trace's ROB detail0, which is authoritative.  Wrong-path
instructions never reach a ROB row that the trace records in full, and
under a changed resolve latency they are not the same instructions the
golden fetched at all, so they must be decoded from the instruction word
in the fetch image.

Only what the model consumes is decoded: the instruction class, which
architectural registers are read and written, and the direct-control
displacement.  No operand values, no immediates beyond branch/jump
targets, no RVC (this profile fetches 32-bit parcels only; `is_rvc`
exists so a caller can detect and reject a compressed parcel rather than
silently mis-decode it).
"""

from .stream import ALU, LOAD, STORE, BRANCH, JUMP, MULDIV, SYSTEM

OP_LOAD, OP_LOAD_FP = 0x03, 0x07
OP_MISC_MEM = 0x0F
OP_IMM, OP_IMM_32 = 0x13, 0x1B
OP_AUIPC, OP_LUI = 0x17, 0x37
OP_STORE, OP_STORE_FP = 0x23, 0x27
OP_AMO = 0x2F
OP_REG, OP_REG_32 = 0x33, 0x3B
OP_BRANCH, OP_JALR, OP_JAL = 0x63, 0x67, 0x6F
OP_SYSTEM = 0x73

# Opcodes that read rs1 / rs2 / write rd.  Anything not listed is treated
# as a plain ALU op reading both sources, which is the conservative
# direction for a dependence model.
_USES_RS1 = frozenset((OP_LOAD, OP_LOAD_FP, OP_IMM, OP_IMM_32, OP_STORE,
                       OP_STORE_FP, OP_AMO, OP_REG, OP_REG_32, OP_BRANCH,
                       OP_JALR, OP_SYSTEM))
_USES_RS2 = frozenset((OP_STORE, OP_STORE_FP, OP_AMO, OP_REG, OP_REG_32,
                       OP_BRANCH))
_NO_RD = frozenset((OP_STORE, OP_STORE_FP, OP_BRANCH))

CONTROL_OPCODES = frozenset((OP_BRANCH, OP_JALR, OP_JAL))


def is_rvc(parcel):
    return (parcel & 3) != 3


def opcode(instr):
    return instr & 0x7F


def is_control(instr):
    return (instr & 0x7F) in CONTROL_OPCODES


def _sext(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


def branch_offset(instr):
    """Signed displacement of a conditional branch (B-type)."""
    v = (((instr >> 31) & 1) << 12 | ((instr >> 7) & 1) << 11 |
         ((instr >> 25) & 0x3F) << 5 | ((instr >> 8) & 0xF) << 1)
    return _sext(v, 13)


def jal_offset(instr):
    """Signed displacement of a direct jump (J-type)."""
    v = (((instr >> 31) & 1) << 20 | ((instr >> 12) & 0xFF) << 12 |
         ((instr >> 20) & 1) << 11 | ((instr >> 21) & 0x3FF) << 1)
    return _sext(v, 21)


def taken_target(pc, instr):
    """Architectural target of a direct control transfer, else None.

    JALR is register-indirect: its target is not a function of the
    encoding, so the caller must supply it from the trace or a predictor.
    """
    op = instr & 0x7F
    if op == OP_BRANCH:
        return (pc + branch_offset(instr)) & 0xFFFFFFFFFFFFFFFF
    if op == OP_JAL:
        return (pc + jal_offset(instr)) & 0xFFFFFFFFFFFFFFFF
    return None


def classify(instr):
    """Instruction class, matching stream.py's class codes."""
    op = instr & 0x7F
    if op in (OP_LOAD, OP_LOAD_FP):
        return LOAD
    if op in (OP_STORE, OP_STORE_FP, OP_AMO):
        return STORE
    if op == OP_BRANCH:
        return BRANCH
    if op in (OP_JAL, OP_JALR):
        return JUMP
    if op in (OP_SYSTEM, OP_MISC_MEM):
        return SYSTEM
    if op in (OP_REG, OP_REG_32) and ((instr >> 25) & 0x7F) == 1:
        return MULDIV                      # M extension: funct7 = 0000001
    return ALU


def decode(instr):
    """(klass, rd, rs1, rs2, uses_rs1, uses_rs2, reg_write, is_hard).

    Register fields that the format does not define are returned as zero
    rather than as whatever immediate bits happen to sit in them, so the
    result compares directly against the trace's ROB detail0 word.
    """
    op = instr & 0x7F
    f3 = (instr >> 12) & 7
    known = op in _USES_RS1 or op in (OP_AUIPC, OP_LUI, OP_JAL, OP_MISC_MEM)
    uses_rs1 = (op in _USES_RS1) if known else True
    uses_rs2 = (op in _USES_RS2) if known else True
    if op == OP_SYSTEM:
        # CSR register forms read rs1; the immediate forms and the
        # environment ops (ecall/ebreak/xRET/sfence) do not.
        uses_rs1 = f3 in (1, 2, 3)
    reg_write = op not in _NO_RD
    rd = ((instr >> 7) & 31) if reg_write else 0
    rs1 = ((instr >> 15) & 31) if uses_rs1 else 0
    rs2 = ((instr >> 20) & 31) if uses_rs2 else 0
    is_hard = op in (OP_SYSTEM, OP_MISC_MEM)
    # The ROB's register-write bit is set for jumps and CSR ops even when
    # rd is x0 -- they still take a rename tag -- so mirror that rather
    # than the architectural "writes a register" test.
    if reg_write and rd == 0 and not (
            op in (OP_JAL, OP_JALR) or (op == OP_SYSTEM and f3 != 0)):
        reg_write = False
    return (classify(instr), rd, rs1, rs2, uses_rs1, uses_rs2, reg_write,
            is_hard)
