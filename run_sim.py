#!/usr/bin/env python3
"""Run the Tiny Tapeout testbench. Same suite as `make -B` in test/."""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> int:
    result = subprocess.run(["make", "-B"], cwd=HERE / "test")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
