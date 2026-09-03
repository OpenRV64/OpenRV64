#!/usr/bin/env python3
"""Entry point: python3 tools/pipeviz <csv> --stats"""

import os
import sys

if __package__ in (None, ""):
    # Executed as a directory/script: put tools/ on the path and import
    # ourselves as a package so relative imports work.
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from pipeviz.cli import main
else:
    from .cli import main

if __name__ == "__main__":
    sys.exit(main())
