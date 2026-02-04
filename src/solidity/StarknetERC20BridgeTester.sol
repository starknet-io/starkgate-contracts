// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";
import "src/solidity/StarknetERC20Bridge.sol";

contract StarknetERC20BridgeTester is StarknetERC20Bridge {
    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
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
