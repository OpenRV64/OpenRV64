"""Parallel parser for openrv64-pipeline-state-v1 CSV traces.

The file is split into byte ranges, one worker process per range (Python
threads serialize on the GIL for CPU-bound work, so real parallelism
means processes).  Each worker builds a partial Trace over its range;
partials are then merged in file order, which preserves first-seen /
last-seen semantics because rows are cycle-ordered.  A worker owns the
lines that *start* inside its range, so rows straddling a boundary are
parsed exactly once.

Pure Python, no dependencies; the CLI re-execs under pypy3 when present.
"""

import os
import sys

from .model import (Insn, Trace, SCHEMA, NO_UID,
                    ST_READY, ST_FIRE, ST_WORKER)

# Column indexes.
_CYCLE = 1
_UID = 2
_TAG = 3
_PC = 4
_INSTR = 5
_STAGE = 6
_SLOT = 7
_LANE = 8
_STATE = 9
_REASON = 10
_BLOCKER = 11
_FLAGS = 12
_D0 = 13
_D1 = 14
_NFIELDS = 15

_ZERO32 = "00000000"
_ZERO64 = "0000000000000000"

# Files below this size are parsed serially; process startup would
# dominate.
_MIN_PARALLEL_BYTES = 8 << 20
# Default worker cap.  8 is plenty for CoreMark-scale traces; the parent's
# serial assembly flattens scaling past ~32 anyway.  Raising this toward
# machine scale (e.g. 256) needs worker-side tree reduction first.
_DEFAULT_MAX_JOBS = 8


def _parse_range(args):
    """Worker: parse lines starting in [start, end) into a partial Trace.

    Returns a partial Trace; use _parse_range_packed for the
    cross-process form.
    """
    path, start, end = args
    trace = Trace()
    insns = trace.insns
    issue_counts = trace.issue_counts
    retire_counts = trace.retire_counts
    sched_cycles = trace.sched_cycles
    rob_head_cycles = trace.rob_head_cycles
    decode_cand = trace.decode_cand
    rob_occ = trace.rob_occ
    rob_completed_occ = trace.rob_completed_occ
    sched_occ = trace.sched_occ
    retire_backpressure_cycles = trace.retire_backpressure_cycles
    ssr = trace.ssr_counts
    min_cycle = None
    max_cycle = -1
    rows = 0
    skipped = 0

    with open(path, "rb", buffering=1 << 22) as f:
        if start == 0:
            pos = 0
        else:
            # Land one byte early: readline() then consumes the line in
            # progress at start-1.  If start-1 holds '\n', the line it
            # ends is the previous worker's and nothing of ours is lost;
            # if not, the consumed line started before us and the
            # previous worker parses it.
            f.seek(start - 1)
            pos = start - 1 + len(f.readline())
        for bline in f:
            if pos >= end:
                break
            pos += len(bline)
            p = bline.decode("ascii", "replace").split(",")
            if len(p) < _NFIELDS:
                if bline.strip():
                    skipped += 1
                continue
            if p[0] == "schema":
                continue  # column header
            rows += 1
            if trace.schema is None:
                trace.schema = p[0]
            cycle = int(p[_CYCLE])
            if cycle > max_cycle:
                max_cycle = cycle
            if min_cycle is None or cycle < min_cycle:
                min_cycle = cycle
            stage = int(p[_STAGE])
            state = int(p[_STATE])
            reason = int(p[_REASON])
            key = (stage << 14) | (state << 9) | reason
            n = ssr.get(key)
            ssr[key] = 1 if n is None else n + 1

            uid = int(p[_UID], 16)
            rec = insns.get(uid)
            if rec is None:
                rec = Insn(uid, int(p[_TAG], 16),
                           int(p[_PC], 16), int(p[_INSTR], 16))
                insns[uid] = rec

            if stage == 8:  # ROB residency: hottest row kind, first
                if rec.rob_info is None:
                    rec.rob_slot = int(p[_SLOT])
                    rec.rob_info = int(p[_D0], 16)
                rec.rob_cycles += 1
                e = rob_head_cycles.get(cycle)
                if e is None:
                    rob_head_cycles[cycle] = [uid, state]
                elif uid < e[0]:
                    e[0] = uid
                    e[1] = state
                n = rob_occ.get(cycle)
                rob_occ[cycle] = 1 if n is None else n + 1
                if state == 11:  # COMPLETE behind head: retire backlog
                    n = rob_completed_occ.get(cycle)
                    rob_completed_occ[cycle] = 1 if n is None else n + 1
            elif stage == 3:  # SCHED entry residency
                if rec.sched_enter_cycle is None:
                    rec.sched_enter_cycle = cycle
                    rec.sched_slot = int(p[_SLOT])
                n = sched_occ.get(cycle)
                sched_occ[cycle] = 1 if n is None else n + 1
                e = sched_cycles.get(cycle)
                if e is None:
                    e = sched_cycles[cycle] = [NO_UID, 0, False]
                if state == ST_READY:
                    rec.sched_ready_cycles += 1
                    e[2] = True
                else:
                    if uid < e[0]:
                        e[0] = uid
                        e[1] = reason
                    rec.sched_wait_cycles += 1
                    r = rec.sched_wait_reasons
                    if r is None:
                        r = rec.sched_wait_reasons = {}
                    n = r.get(reason)
                    r[reason] = 1 if n is None else n + 1
                    b = p[_BLOCKER]
                    if b != _ZERO32:
                        rec.sched_blocker = int(b, 16)
            elif stage == 1:  # FETCH residency
                rec.fetch_cycles += 1
                if rec.fetch_first_cycle is None:
                    rec.fetch_first_cycle = cycle
                    rec.fetch_lane = int(p[_LANE])
                    rec.fetch_flags = int(p[_FLAGS], 16)
                if rec.instr == 0:  # word can arrive on a later row
                    rec.instr = int(p[_INSTR], 16)
            elif stage == 2:  # DECODE admission gate
                n = decode_cand.get(cycle)
                decode_cand[cycle] = 1 if n is None else n + 1
                if state == ST_FIRE:
                    rec.decode_cycle = cycle
                else:
                    rec.decode_wait_cycles += 1
                    r = rec.decode_wait_reasons
                    if r is None:
                        r = rec.decode_wait_reasons = {}
                    n = r.get(reason)
                    r[reason] = 1 if n is None else n + 1
            elif stage == 5:  # EXEC offer / worker
                if state == ST_FIRE:
                    rec.issue_cycle = cycle
                    rec.issue_pipe = int(p[_LANE])
                    n = issue_counts.get(cycle)
                    issue_counts[cycle] = 1 if n is None else n + 1
                elif state == ST_WORKER:
                    rec.exec_worker_cycles += 1
                else:
                    rec.exec_wait_cycles += 1
            elif stage == 6:  # COMPLETE
                if state == ST_FIRE:
                    rec.complete_cycle = cycle
                    rec.wb_value = int(p[_D0], 16)
                    rec.next_pc = int(p[_D1], 16)
                else:
                    rec.complete_wait_cycles += 1
            elif stage == 7:  # LSQ residency (state LOAD=8 / STORE=9)
                rec.lsq_cycles += 1
                if state == 9:
                    rec.lsq_is_store = True
                r = rec.lsq_wait_reasons
                if r is None:
                    r = rec.lsq_wait_reasons = {}
                n = r.get(reason)
                r[reason] = 1 if n is None else n + 1
                if rec.mem_vaddr is None:
                    rec.mem_vaddr = int(p[_D0], 16)
                d1 = p[_D1]
                # Last column carries the newline; startswith of an
                # all-zero 16-char prefix is the zero test.
                if not d1.startswith(_ZERO64):
                    rec.mem_paddr = int(d1, 16)
            elif stage == 9:  # RETIRE
                if state == ST_FIRE:
                    rec.retire_cycle = cycle
                    n = retire_counts.get(cycle)
                    retire_counts[cycle] = 1 if n is None else n + 1
                else:
                    rec.retire_wait_cycles += 1
                    retire_backpressure_cycles.add(cycle)
            elif stage == 4:  # REGREAD gather buffers
                rec.regread_cycles += 1

    trace.rows = rows
    trace.skipped_rows = skipped
    trace.min_cycle = min_cycle
    trace.max_cycle = max_cycle if max_cycle >= 0 else None
    return trace


def _parse_range_packed(args):
    """Worker wrapper: flatten Insn records into tuples.  Pickling flat
    tuples is several times cheaper than pickling slotted objects, and
    the transfer back to the parent is the scaling bottleneck."""
    t = _parse_range(args)
    packed = [r.pack() for r in t.insns.values()]
    return (t.schema, t.rows, t.skipped_rows, t.min_cycle, t.max_cycle,
            packed, t.ssr_counts, t.issue_counts, t.retire_counts,
            t.sched_cycles, t.rob_head_cycles, t.retire_backpressure_cycles,
            t.rob_occ, t.rob_completed_occ, t.sched_occ, t.decode_cand)


def _merge_dict(a, b):
    if b is None:
        return a
    if a is None:
        return b
    for k, v in b.items():
        n = a.get(k)
        a[k] = v if n is None else n + v
    return a


def _merge_insn(a, b):
    """Fold b (from a later file range) into a."""
    a.fetch_cycles += b.fetch_cycles
    if a.fetch_first_cycle is None:
        a.fetch_first_cycle = b.fetch_first_cycle
        a.fetch_lane = b.fetch_lane
        a.fetch_flags = b.fetch_flags
    if a.instr == 0:
        a.instr = b.instr
    if b.decode_cycle is not None:
        a.decode_cycle = b.decode_cycle
    a.decode_wait_cycles += b.decode_wait_cycles
    a.decode_wait_reasons = _merge_dict(a.decode_wait_reasons,
                                        b.decode_wait_reasons)
    if a.sched_enter_cycle is None:
        a.sched_enter_cycle = b.sched_enter_cycle
        a.sched_slot = b.sched_slot
    a.sched_ready_cycles += b.sched_ready_cycles
    a.sched_wait_cycles += b.sched_wait_cycles
    a.sched_wait_reasons = _merge_dict(a.sched_wait_reasons,
                                       b.sched_wait_reasons)
    if b.sched_blocker:
        a.sched_blocker = b.sched_blocker
    a.regread_cycles += b.regread_cycles
    if b.issue_cycle is not None:
        a.issue_cycle = b.issue_cycle
        a.issue_pipe = b.issue_pipe
    a.exec_wait_cycles += b.exec_wait_cycles
    a.exec_worker_cycles += b.exec_worker_cycles
    if b.complete_cycle is not None:
        a.complete_cycle = b.complete_cycle
        a.wb_value = b.wb_value
        a.next_pc = b.next_pc
    a.complete_wait_cycles += b.complete_wait_cycles
    a.lsq_cycles += b.lsq_cycles
    a.lsq_is_store = a.lsq_is_store or b.lsq_is_store
    a.lsq_wait_reasons = _merge_dict(a.lsq_wait_reasons,
                                     b.lsq_wait_reasons)
    if a.mem_vaddr is None:
        a.mem_vaddr = b.mem_vaddr
    if b.mem_paddr is not None:
        a.mem_paddr = b.mem_paddr
    if a.rob_info is None:
        a.rob_info = b.rob_info
        a.rob_slot = b.rob_slot
    a.rob_cycles += b.rob_cycles
    if b.retire_cycle is not None:
        a.retire_cycle = b.retire_cycle
    a.retire_wait_cycles += b.retire_wait_cycles


def parse_file(path, progress=None, jobs=None):
    """Parse a trace CSV into a Trace.

    jobs=None picks a worker count from the file size and CPU count;
    jobs=1 forces serial.  progress, if given, is called with the row
    count as parsing advances.
    """
    size = os.path.getsize(path)
    if jobs is None or jobs < 1:
        if size < _MIN_PARALLEL_BYTES:
            jobs = 1
        else:
            jobs = min(_DEFAULT_MAX_JOBS, os.cpu_count() or 1)
    jobs = min(jobs, max(1, size // (1 << 20)))  # >=1MB per worker

    if jobs == 1:
        trace = _parse_range((path, 0, size))
    else:
        import multiprocessing
        bounds = [(path, size * i // jobs, size * (i + 1) // jobs)
                  for i in range(jobs)]
        ctx = multiprocessing.get_context("fork")
        trace = Trace()
        insns = trace.insns
        unpack = Insn.unpack
        with ctx.Pool(jobs) as pool:
            # imap yields in submission order; assembling in file order
            # preserves first/last-seen semantics.
            for payload in pool.imap(_parse_range_packed, bounds):
                (schema, rows, skipped, mn, mx,
                 packed, ssr, ic, rc, sc, rhc, rwc,
                 ro, rco, so, dcand) = payload
                trace.rows += rows
                trace.skipped_rows += skipped
                if trace.schema is None:
                    trace.schema = schema
                if mn is not None:
                    if trace.min_cycle is None or mn < trace.min_cycle:
                        trace.min_cycle = mn
                    if trace.max_cycle is None or mx > trace.max_cycle:
                        trace.max_cycle = mx
                _merge_dict(trace.ssr_counts, ssr)
                _merge_dict(trace.issue_counts, ic)
                _merge_dict(trace.retire_counts, rc)
                tsc = trace.sched_cycles
                for cyc, e in sc.items():
                    ea = tsc.get(cyc)
                    if ea is None:
                        tsc[cyc] = e
                    else:
                        if e[0] < ea[0]:
                            ea[0] = e[0]
                            ea[1] = e[1]
                        ea[2] = ea[2] or e[2]
                trh = trace.rob_head_cycles
                for cyc, e in rhc.items():
                    ea = trh.get(cyc)
                    if ea is None or e[0] < ea[0]:
                        trh[cyc] = e
                trace.retire_backpressure_cycles |= rwc
                _merge_dict(trace.rob_occ, ro)
                _merge_dict(trace.rob_completed_occ, rco)
                _merge_dict(trace.sched_occ, so)
                _merge_dict(trace.decode_cand, dcand)
                for t in packed:
                    uid = t[0]
                    ra = insns.get(uid)
                    if ra is None:
                        insns[uid] = unpack(t)
                    else:
                        _merge_insn(ra, unpack(t))
                if progress is not None:
                    progress(trace.rows)

    trace.path = path
    trace.parse_jobs = jobs
    if trace.schema is not None and trace.schema != SCHEMA:
        sys.stderr.write("pipeviz: warning: schema %r, expected %r\n"
                         % (trace.schema, SCHEMA))
    if trace.skipped_rows:
        sys.stderr.write("pipeviz: warning: skipped %d malformed rows\n"
                         % trace.skipped_rows)
    return trace
