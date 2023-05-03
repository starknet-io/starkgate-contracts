// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/libraries/NamedStorage.sol";
import "contracts/messaging/IStarknetMessaging.sol";

abstract contract StarknetTokenStorage {
    // Random storage slot tags.
    string internal constant BRIDGED_TOKEN_TAG = "STARKNET_ERC20_TOKEN_BRIDGE_TOKEN_ADDRESS";
    string internal constant L2_TOKEN_TAG = "STARKNET_TOKEN_BRIDGE_L2_TOKEN_CONTRACT";
    string internal constant MAX_DEPOSIT_TAG = "STARKNET_TOKEN_BRIDGE_MAX_DEPOSIT";
    string internal constant MAX_TOTAL_BALANCE_TAG = "STARKNET_TOKEN_BRIDGE_MAX_TOTAL_BALANCE";
    string internal constant MESSAGING_CONTRACT_TAG = "STARKNET_TOKEN_BRIDGE_MESSAGING_CONTRACT";
    string internal constant DEPOSITOR_ADDRESSES_TAG = "STARKNET_TOKEN_BRIDGE_DEPOSITOR_ADDRESSES";
    string internal constant BRIDGE_IS_ACTIVE_TAG = "STARKNET_TOKEN_BRIDGE_IS_ACTIVE";

    // Storage Getters.
    function bridgedToken() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGED_TOKEN_TAG);
    }

    function l2TokenBridge() internal view returns (uint256) {
        return NamedStorage.getUintValue(L2_TOKEN_TAG);
    }

    function maxDeposit() public view returns (uint256) {
        return NamedStorage.getUintValue(MAX_DEPOSIT_TAG);
    }

    function maxTotalBalance() public view returns (uint256) {
        return NamedStorage.getUintValue(MAX_TOTAL_BALANCE_TAG);
    }

    function messagingContract() internal view returns (IStarknetMessaging) {
        return IStarknetMessaging(NamedStorage.getAddressValue(MESSAGING_CONTRACT_TAG));
    }

    function isActive() public view returns (bool) {
        return NamedStorage.getBoolValue(BRIDGE_IS_ACTIVE_TAG);
    }

    function depositors() internal pure returns (mapping(uint256 => address) storage) {
        return NamedStorage.uintToAddressMapping(DEPOSITOR_ADDRESSES_TAG);
    }

    // Storage Setters.
    function bridgedToken(address contract_) internal {
        NamedStorage.setAddressValueOnce(BRIDGED_TOKEN_TAG, contract_);
    }

    function l2TokenBridge(uint256 value) internal {
        NamedStorage.setUintValueOnce(L2_TOKEN_TAG, value);
    }

    function maxDeposit(uint256 value) internal {
        NamedStorage.setUintValue(MAX_DEPOSIT_TAG, value);
    }

    function maxTotalBalance(uint256 value) internal {
        NamedStorage.setUintValue(MAX_TOTAL_BALANCE_TAG, value);
    }

    function messagingContract(address contract_) internal {
        NamedStorage.setAddressValueOnce(MESSAGING_CONTRACT_TAG, contract_);
    }

    function setActive() internal {
        return NamedStorage.setBoolValue(BRIDGE_IS_ACTIVE_TAG, true);
    }
}
