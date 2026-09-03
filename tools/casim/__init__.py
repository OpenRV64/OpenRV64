"""casim -- cycle-accurate backend model for the OpenRV64 3P Tomasulo core.

The model consumes a frontend instruction stream (either replayed from a
golden pipeline-state-v1 trace, or synthesised at full speed) and drives it
through a per-cycle model of the scheduler, execution pipes, ROB, and
in-order retirement.  Its purpose is bottleneck exploration: lift a
restriction (frontend delivery, scheduler depth, a pipe, a barrier) and see
where the backend clogs.

Timing is anchored to top-of-trunk RTL (rtl/core/rename/tomasulo.v,
rtl/core/dispatch/dispatch_window_3p.v and the exec/retire path).  It is
validated against committed golden traces to per-instruction cycle accuracy.

Numeric trace ABI: rtl/core/trace/tomasulo-trace-defs.v.
"""
