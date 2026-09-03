"""camsim -- cycle-accurate modular simulator.

A core model assembled as modules on an event bus rather than as one program.
Each module announces the signals it drives and subscribes to the ones it
reads; the bus wires them at elaboration and clocks them.  Nothing calls
anything directly, so a module can be replaced by a different implementation,
by a recording, by an ideal stub, or by a process on the other end of a pipe,
without the modules around it changing.

The bus is a clock, not a queue -- see ``bus.py`` for why that distinction is
the whole design.  ``module.py`` is the protocol a module implements,
``wire.py`` the same protocol serialised for out-of-process modules.

Sibling: ``tools/casim`` is the monolithic model this is meant to grow into a
modular form of.  Nothing is copied from it yet.
"""

from .module import Module, Signal, out, ASYNC, REG, LEVEL, PULSE
from .bus import Bus, AsyncLoop, Elaboration

__all__ = ["Module", "Signal", "out", "ASYNC", "REG", "LEVEL", "PULSE",
           "Bus", "AsyncLoop", "Elaboration"]
