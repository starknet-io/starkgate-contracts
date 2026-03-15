// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/Addresses.sol";
import "src/solidity/StarknetEthBridge.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";

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
    }

    function setBridgedToken(address contract_) external {
        NamedStorage.setAddressValueOnce(BRIDGED_TOKEN_TAG, contract_);
    }
}
