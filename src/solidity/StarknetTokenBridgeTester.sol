// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;
import "src/solidity/StarknetTokenBridge.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";

contract StarknetTokenBridgeTester is StarknetTokenBridge {
    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
    }

    function setTokenStatus(address token, TokenStatus status) external {
        tokenSettings()[token].tokenStatus = status;
    }
}
