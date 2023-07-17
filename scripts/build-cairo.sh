#!/bin/bash
pushd $(dirname $0)/..

mkdir -p cairo_contracts

scripts/starknet-compile.py src  --contract-path src::permissioned_erc20::PermissionedERC20 cairo_contracts/PermissionedERC20.sierra
scripts/starknet-compile.py src  --contract-path src::token_bridge::TokenBridge cairo_contracts/TokenBridge.sierra

popd
