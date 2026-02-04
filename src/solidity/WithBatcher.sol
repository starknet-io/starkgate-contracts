// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

interface ILegacyWithdraw {
    function withdraw(uint256 amount, address recipient) external;
}

interface ITokenWithdraw {
    function withdraw(
        address token,
        uint256 amount,
        address recipient
    ) external;
}

struct LegacyWithdrawData {
    address bridge;
    uint256 amount;
    address recipient;
}

struct TokenWithdrawData {
    address bridge;
    address token;
    uint256 amount;
    address recipient;
}

uint8 constant MAX_WITHRAWALS = 128;

contract WithBatcher {
    event FailedWithdrawals(LegacyWithdrawData withdrawData);
    event FailedTokenWithdrawals(TokenWithdrawData withdrawData);

    function withdrawBatch(LegacyWithdrawData[] calldata pendingWithdrawals) external {
        require(pendingWithdrawals.length <= MAX_WITHRAWALS);

        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            LegacyWithdrawData memory withData = pendingWithdrawals[i];
            address bridge = withData.bridge;

            bytes memory _calldata = abi.encodeWithSelector(
                ILegacyWithdraw(bridge).withdraw.selector,
                withData.amount,
                withData.recipient
            );

            (bool success, ) = bridge.call(_calldata);
            if (!success) {
                emit FailedWithdrawals(withData);
            }
        }
    }

    function tokenWithdrawBatch(TokenWithdrawData[] calldata pendingWithdrawals) external {
        require(pendingWithdrawals.length <= MAX_WITHRAWALS);

        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            TokenWithdrawData memory tokenWithData = pendingWithdrawals[i];
            address bridge = tokenWithData.bridge;

            bytes memory _calldata = abi.encodeWithSelector(
                ITokenWithdraw(bridge).withdraw.selector,
                tokenWithData.token,
                tokenWithData.amount,
                tokenWithData.recipient
            );

            (bool success, ) = bridge.call(_calldata);
            if (!success) {
                emit FailedTokenWithdrawals(tokenWithData);
            }
        }
    }
}
