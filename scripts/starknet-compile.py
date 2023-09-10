#!/usr/bin/env python3

import sys
import argparse
import subprocess
import os

ROOT_DIR = os.path.dirname(os.path.dirname(__file__))
EXECUTABLE = os.path.join(ROOT_DIR, ".downloads", "cairo", "bin", "starknet-compile")
EXPECTED_EXECUTABLE_VERSION = "starknet-compile 2.2.0"


def main():
    parser = argparse.ArgumentParser(add_help=False)
    _, args = parser.parse_known_args()
    # Check version
    try:
        executable_version = (
            subprocess.check_output([EXECUTABLE, "--version"]).decode("utf-8").strip()
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print("Setup Error! Run : 'sh ./scripts/setup.sh' to solve this problem.")
        sys.exit(1)

    assert executable_version == EXPECTED_EXECUTABLE_VERSION, (
        f"Wrong version got: {executable_version}, Expected: {EXPECTED_EXECUTABLE_VERSION}."
        "Run : 'sh ./scripts/setup.sh' to solve this problem."
    )

    try:
        subprocess.check_call([EXECUTABLE, *args])
    except subprocess.CalledProcessError as e:
        sys.exit(e.returncode)


if __name__ == "__main__":
    sys.exit(main())
