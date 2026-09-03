"""pipeviz: parser and analysis library for openrv64 pipeline-state traces.

Library use:
    from pipeviz import parse_file
    trace = parse_file("pipeline-state.csv")
    trace.insns[uid]              # per-instruction lifetime records
    trace.issue_width_histogram() # cycles issuing 0..3 insns

CLI:
    python3 tools/pipeviz pipeline-state.csv --stats
(re-execs itself under pypy3 automatically when available)
"""

from .model import (Insn, Trace, SCHEMA, opcode_is_load,
                    opcode_is_store, stage_name, state_name, reason_name)
from .parser import parse_file

__all__ = ["Insn", "Trace", "SCHEMA", "opcode_is_load",
           "opcode_is_store", "stage_name", "state_name", "reason_name",
           "parse_file"]
