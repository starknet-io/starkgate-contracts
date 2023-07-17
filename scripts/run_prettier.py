#!/usr/bin/env python3.9

import argparse
import subprocess
import sys

from script_utils import color_txt, find_command, git_files


def main():
    parser = argparse.ArgumentParser(description="Run Prettier on Solidity files")
    parser.add_argument("--files", nargs="+", help="Run on specified files. Ignore other flags.")

    parser.add_argument("--fix", action="store_true", help="Fix formatting errors")
    parser.add_argument("--quiet", "-q", dest="verbose", action="store_false")

    args = parser.parse_args()

    extensions = ["sol"]
    command_args = [find_command("prettier")]
    if args.fix:
        command_args.append("-w")
    else:
        command_args.append("-c")

    if args.files:
        files = [path for path in args.files if path.endswith(tuple(extensions))]
    else:
        files = git_files(extensions=extensions)

    if args.verbose:
        print(
            color_txt(
                "yellow",
                "=== Running black on the following files: ===\n" + "\n".join(files),
            )
        )
        sys.stdout.flush()

    if len(files) > 0:
        try:
            subprocess.check_output(command_args + files, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as error:
            print(error.stdout.decode("utf-8"))
            print(color_txt("red", f"=== prettier failed ===\n"))
            sys.exit(1)

    if args.verbose:
        print(color_txt("yellow", "=== prettier completed successfully ==="))


if __name__ == "__main__":
    main()
