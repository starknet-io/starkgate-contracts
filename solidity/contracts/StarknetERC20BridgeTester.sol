// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/StarknetERC20Bridge.sol";
import "contracts/messaging/IStarknetMessaging.sol";

contract StarknetERC20BridgeTester is StarknetERC20Bridge {
    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
    }
}
