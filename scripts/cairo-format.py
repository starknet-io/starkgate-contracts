#!/usr/bin/env python3

import sys
import argparse
import subprocess
from pathlib import Path

# --- Configuration Constants ---
# Find the project root directory (two levels up from this script's location)
ROOT_DIR = Path(__file__).resolve().parent.parent
EXECUTABLE_NAME = "cairo-format"
EXECUTABLE = ROOT_DIR / ".downloads" / "cairo" / "bin" / EXECUTABLE_NAME
EXPECTED_EXECUTABLE_VERSION = f"{EXECUTABLE_NAME} 2.10.1"


def main() -> int:
    """
    Checks the installed cairo-format version and executes the formatter 
    with any provided command-line arguments.
    
    Returns:
        int: The exit code of the cairo-format executable, or 1 on setup error.
    """
    
    # 1. Capture arguments passed to this wrapper script
    parser = argparse.ArgumentParser(add_help=False)
    # Use parse_known_args to capture all unhandled arguments for the wrapped executable
    _, args = parser.parse_known_args()

    # 2. Check the executable version
    try:
        executable_version = (
            subprocess.check_output([str(EXECUTABLE), "--version"], stderr=subprocess.STDOUT)
            .decode("utf-8")
            .strip()
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Handle cases where the executable is missing or the initial call fails (e.g., during setup)
        print("Setup Error! The required executable is missing or failed to run.")
        print("Run : 'sh ./scripts/setup.sh' to solve this problem.")
        return 1

    # 3. Verify the expected version
    if executable_version != EXPECTED_EXECUTABLE_VERSION:
        print(f"Version Mismatch Error!")
        print(f"  Got: {executable_version}, Expected: {EXPECTED_EXECUTABLE_VERSION}.")
        print("Run : 'sh ./scripts/setup.sh' to solve this problem.")
        return 1
        
    # 4. Execute the wrapped formatter with all arguments
    try:
        # Use subprocess.check_call to run the command and inherit the exit code
        # We pass the executable path as a string explicitly for compatibility.
        subprocess.check_call([str(EXECUTABLE), *args])
        return 0
    except subprocess.CalledProcessError as e:
        # If the formatter exits with a non-zero code (e.g., formatting error),
        # return that exit code to the caller of the wrapper script.
        return e.returncode
    except FileNotFoundError:
        # Should be caught by the version check, but included for robustness
        print(f"Error: Executable not found at {EXECUTABLE}. Run setup script.")
        return 1


if __name__ == "__main__":
    # Use sys.exit to return the exit code returned by main()
    sys.exit(main())
