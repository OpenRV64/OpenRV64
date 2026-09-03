"""Machine configuration.

Defaults mirror the top-of-trunk documented Tomasulo profile that produced
the committed golden traces (run.log run_id
coremark-sv39-3p-tomasulo-oracle-magic-l1i-trace-ddr3): 64-entry ROB,
32-entry scheduler, 63 physical registers, 3-wide decode/issue/retire, the
EX0/EX1/MEM0/MEM1 pipe capability split, and magic (single-cycle) memory.

Every field here is a knob for bottleneck exploration.  `Config.ideal_*`
switches are the "take the restriction off" levers Bill asked for: unbound
the frontend, the scheduler, or the ROB and watch what still clogs.
"""


class Config(object):
    __slots__ = (
        "rob_depth", "sched_depth", "phys_regs",
        "decode_width", "issue_width", "retire_width",
        "lat_alu", "lat_branch", "lat_jump", "lat_load", "lat_store",
        "wakeup_delay", "alu_forward",
        "mem_load_pipes", "mem_store_pipes",
        "store_at_lsq_head", "in_order_memory",
        "ideal_frontend", "ideal_sched", "ideal_rob", "ideal_prf",
        "magic_memory", "mem_replay",
        # Frontend model (frontend.py).
        "fetch_width", "fetch_queue_depth", "fetch_block_bytes",
        "fetch_window_blocks", "l1i_refill_cycles", "stash_unpredicted",
        "taken_redirect_delay", "mispredict_redirect_delay",
        "resolve_latency", "squash_wrong_path", "squash_delay",
    )

    def __init__(self):
        # Structural capacity.
        self.rob_depth = 64
        self.sched_depth = 32
        self.phys_regs = 63            # merged file; ~31 speculative over 32 arch

        # Pipeline widths.
        self.decode_width = 3
        self.issue_width = 3           # EX0 + EX1 + one MEM per cycle in practice
        self.retire_width = 3

        # Execution latency, issue->complete, in cycles (measured from golden).
        self.lat_alu = 1
        self.lat_branch = 1
        self.lat_jump = 1
        self.lat_load = 3              # magic-L1I base; misses/guard add tail
        self.lat_store = 1            # address/data ready; launch handled at head

        # Wakeup: a dependent's source is observable the cycle after the
        # producer's completion write-ack (completion-driven, not issue-time).
        # This reproduces the measured ALU->ALU issue gap of +2.
        self.wakeup_delay = 1
        # ALU->ALU completion forwarding (COMPLETION_FORWARD_MASK=7): when on,
        # an ALU/EX0 consumer may wake on the forward broadcast at the same
        # delay; kept as a switch for ablation.
        self.alu_forward = True

        # Pipe capability (fixed lanes): loads -> MEM0, stores/AMO -> MEM1.
        self.mem_load_pipes = ("MEM0",)
        self.mem_store_pipes = ("MEM1",)

        # Memory ordering policy.
        self.store_at_lsq_head = True   # store launches at LSQ head / past spec
        self.in_order_memory = True     # loads ordered behind older unissued mem

        # Idealisation levers ("take the restriction off").
        self.ideal_frontend = False     # inject the whole stream at full width
        self.ideal_sched = False        # unbounded scheduler
        self.ideal_rob = False          # unbounded ROB
        self.ideal_prf = False          # unbounded physical registers
        self.magic_memory = True        # every load/store hits at base latency
        self.mem_replay = False         # inject real per-load latency from the golden (real-mem goldens)

        # --- frontend model -------------------------------------------
        # Candidate supply.  fetch_3w presents up to three cascaded
        # candidates per cycle from a resident window of 512-bit L1I
        # fetch blocks (CORE_3P_ICX_L2_L1I_FETCH_WIDTH=512, carousel
        # LINE_DEPTH=4).
        self.fetch_width = 3
        self.fetch_queue_depth = 3
        self.fetch_block_bytes = 64
        self.fetch_window_blocks = 4
        # Magic-L1I default: a requested block is usable immediately.
        # Raise this to model a real I-side and the carousel starts to
        # matter.
        self.l1i_refill_cycles = 0
        self.stash_unpredicted = True   # fetch_3w stashes the other side

        # Redirect timing, measured on pipeline-state-52448 (bp8):
        # a predicted-taken transfer redirects fetch one cycle after it
        # is admitted (73% at +1, 26% at +2); a mispredict delivers the
        # corrected path one cycle after the branch completes (99%).
        self.taken_redirect_delay = 1
        self.mispredict_redirect_delay = 1
        # 0 = replay the golden's per-branch dispatch->complete latency.
        # A constant asks what the frontend would do given resolution
        # that fast; frontend-only mode has no backend to compute it.
        self.resolve_latency = 0

        # Backend handling of speculative work (backend-only mode).
        self.squash_wrong_path = True   # remove shadow work at resolution
        self.squash_delay = 1           # cycles from resolve to slot release

    def eff_sched_depth(self):
        return 1 << 30 if self.ideal_sched else self.sched_depth

    def eff_rob_depth(self):
        return 1 << 30 if self.ideal_rob else self.rob_depth

    def eff_phys_regs(self):
        return 1 << 30 if self.ideal_prf else self.phys_regs

    def describe(self):
        parts = ["rob=%d" % self.eff_rob_depth() if not self.ideal_rob
                 else "rob=inf",
                 "sched=%d" % self.sched_depth if not self.ideal_sched
                 else "sched=inf",
                 "prf=%d" % self.phys_regs if not self.ideal_prf
                 else "prf=inf",
                 "w=%d/%d/%d" % (self.decode_width, self.issue_width,
                                 self.retire_width),
                 "ld=%d" % self.lat_load]
        if self.ideal_frontend:
            parts.append("frontend=ideal")
        return " ".join(parts)

    def describe_frontend(self):
        parts = ["fetch=%dw/q%d" % (self.fetch_width, self.fetch_queue_depth),
                 "block=%dB x%d" % (self.fetch_block_bytes,
                                    self.fetch_window_blocks),
                 "refill=%d" % self.l1i_refill_cycles,
                 "redirect=+%d/+%d" % (self.taken_redirect_delay,
                                       self.mispredict_redirect_delay),
                 "resolve=%s" % ("golden replay" if not self.resolve_latency
                                 else self.resolve_latency),
                 "gate=%d" % self.decode_width]
        return " ".join(parts)
