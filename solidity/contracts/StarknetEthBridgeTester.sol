// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "./libraries/Addresses.sol";
import "./StarknetEthBridge.sol";
import "./messaging/IStarknetMessaging.sol";

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
}
