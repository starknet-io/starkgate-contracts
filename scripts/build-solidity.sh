#!/bin/bash
pushd $(dirname $0)/..

mkdir -p artifacts

.downloads/solc-0.8.20 $(cat src/solidity/files_to_compile.txt) --allow-paths .=., --overwrite --combined-json abi,bin -o artifacts
scripts/extract_artifacts.py

popd
