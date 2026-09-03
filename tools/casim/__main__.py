#!/usr/bin/env python3
"""Entry point: python3 tools/casim <csv> --validate"""
import os
import sys
if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from casim.cli import main
else:
    from .cli import main
if __name__ == "__main__":
    sys.exit(main())
