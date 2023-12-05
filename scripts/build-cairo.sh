#!/bin/bash
pushd $(dirname $0)/..
set -e
mkdir -p cairo_contracts

scripts/starknet-compile.py src  --contract-path src::update_712_vars_eic::Update712VarsEIC cairo_contracts/Update712VarsEIC.sierra
scripts/starknet-compile.py src  --contract-path src::roles_init_eic::RolesExternalInitializer cairo_contracts/RolesExternalInitializer.sierra
scripts/starknet-compile.py src  --contract-path src::legacy_bridge_eic::LegacyBridgeUpgradeEIC cairo_contracts/LegacyBridgeUpgradeEIC.sierra
scripts/starknet-compile.py src  --contract-path src::token_bridge::TokenBridge cairo_contracts/TokenBridge.sierra
scripts/starknet-compile.py src  --contract-path openzeppelin::token::erc20::presets::erc20votes::ERC20VotesPreset cairo_contracts/ERC20VotesPreset.sierra
scripts/starknet-compile.py src  --contract-path  openzeppelin::token::erc20_v070::erc20::ERC20 cairo_contracts/ERC20.sierra
set +e
popd
