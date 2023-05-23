// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "./StarknetERC20Bridge.sol";
import "./messaging/IStarknetMessaging.sol";

contract StarknetERC20BridgeTester is StarknetERC20Bridge {
    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
    }
}
