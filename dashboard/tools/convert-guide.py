#!/usr/bin/env python3
"""CLI wrapper — delegates to convert_guide module."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_guide import main

if __name__ == "__main__":
    main()
