// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;
import "src/solidity/StarknetERC20Bridge.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";

contract StarknetERC20BridgeTester is StarknetERC20Bridge {
    uint256 marker;

    function setMarker(uint256 marker_) external {
        marker = marker_;
    }

    function setTokenStatus(address token, TokenStatus status) external {
        tokenSettings()[token].tokenStatus = status;
    }

    function setBridgedToken(address contract_) external {
        NamedStorage.setAddressValueOnce(BRIDGED_TOKEN_TAG, contract_);
    }
}
