// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/libraries/Addresses.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/StarknetEthBridge.sol";
import "contracts/starkware/starknet/solidity/IStarknetMessaging.sol";

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
