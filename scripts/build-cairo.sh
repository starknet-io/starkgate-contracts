#!/bin/bash
pushd $(dirname $0)/..

mkdir -p cairo_contracts

scripts/starknet-compile.py src  --contract-path src::permissioned_erc20::PermissionedERC20 cairo_contracts/PermissionedERC20.sierra
scripts/starknet-compile.py src  --contract-path src::token_bridge::TokenBridge cairo_contracts/TokenBridge.sierra
scripts/starknet-compile.py src  --contract-path openzeppelin::token::erc20::erc20::ERC20 cairo_contracts/ERC20.sierra
scripts/starknet-compile.py src  --contract-path openzeppelin::token::erc20::presets::erc20votes::ERC20VotesPreset cairo_contracts/ERC20VotesPreset.sierra

popd
