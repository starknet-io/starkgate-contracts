#!/usr/bin/env python3

import json
import os
from argparse import ArgumentParser


def remove_json_suffix(file_name: str):
    suffix = ".json"
    if file_name.endswith(suffix):
        return file_name[: -len(suffix)]
    return file_name


def main():
    parser = ArgumentParser()
    parser.add_argument(
        "--input_json",
        type=str,
        help="The path to the combined.json file.",
        required=False,
        default="artifacts/combined.json",
    )
    args = parser.parse_args()

    combined_json = json.load(open(os.path.join(args.input_json)))

    for path_and_name, val in combined_json["contracts"].items():
        _, contract_name = path_and_name.split(":")

        # 1. We cannot put "0x" in case of empty bin, as this would not prevent
        #    loading an empty (virtual) contract. (We want it to fail)
        # 2. Note that we can't put an assert len(val['bin']) > 0 here, because some contracts
        #    are pure virtual and others lack external and public functions.
        bytecode = None
        if len(val["bin"]) > 0:
            bytecode = "0x" + val["bin"]

        # Support both solc-0.6 & solc-0.8 output format.
        # In solc-0.6 the abi is a list in a json string,
        # whereas in 0.8 it's a plain json.
        try:
            abi = json.loads(val["abi"])
        except TypeError:
            abi = val["abi"]

        artifact = {
            "contractName": contract_name,
            "abi": abi,
            "bytecode": bytecode,
        }
        json.dump(artifact, open(f"artifacts/{contract_name}.json", "w"), indent=4)


if __name__ == "__main__":
    main()
