// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/Addresses.sol";
import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";
import "src/solidity/StarknetEthBridge.sol";

contract StarknetEthBridgeTester is StarknetEthBridge {
    using Addresses for address;

    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
    }

    function receiveEth() external payable {}

    function sendEth(uint256 amount) external {
        address(msg.sender).performEthTransfer(amount);
    }

    function setTokenStatus(address token, TokenStatus status) external {
        tokenSettings()[token].tokenStatus = status;
        if (bridgedToken() == address(0x0)) {
            setBridgedToken(token);
        }
    }

    function setBridgedToken(address contract_) internal {
        NamedStorage.setAddressValue(BRIDGED_TOKEN_TAG, contract_);
    }
}
