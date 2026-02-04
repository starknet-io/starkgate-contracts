// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/solidity/tokens/ERC20/IERC20.sol";
import "src/solidity/StarkgateConstants.sol";

/**
    A library to provide withdrawal limit functionality.
 */
library WithdrawalLimit {
    uint256 constant DEFAULT_WITHDRAW_LIMIT_PCT = 5;
    string internal constant WITHDRAW_LIMIT_PCT_TAG = "WITHDRAWL_LIMIT_WITHDRAW_LIMIT_PCT_SLOT_TAG";
    string internal constant INTRADAY_QUOTA_TAG = "WITHDRAWL_LIMIT_INTRADAY_QUOTA_SLOT_TAG";

    function getWithdrawLimitPct() internal view returns (uint256) {
        return NamedStorage.getUintValue(WITHDRAW_LIMIT_PCT_TAG);
    }

    function setWithdrawLimitPct(uint256 value) internal {
        NamedStorage.setUintValue(WITHDRAW_LIMIT_PCT_TAG, value);
    }

    // Returns the key for the intraday allowance mapping.
    function withdrawQuotaKey(address token) internal view returns (bytes32) {
        uint256 day = block.timestamp / 86400;
        return keccak256(abi.encode(token, day));
    }

    /**
        Calculates the intraday allowance for a given token.
        The allowance is calculated as a percentage of the current balance.
     */
    function calculateIntradayAllowance(address token) internal view returns (uint256) {
        uint256 currentBalance;
        // If the token is Eth and not an ERC20 - calculate balance accordingly.
        if (token == ETH) {
            currentBalance = address(this).balance;
        } else {
            currentBalance = IERC20(token).balanceOf(address(this));
        }
        uint256 withdrawLimitPct = getWithdrawLimitPct();
        return (currentBalance * withdrawLimitPct) / 100;
    }

    /**
        Returns the intraday quota mapping.
     */
    function intradayQuota() internal pure returns (mapping(bytes32 => uint256) storage) {
        return NamedStorage.bytes32ToUint256Mapping(INTRADAY_QUOTA_TAG);
    }

    // The offset is used to distinguish between an unset value and a value of 0.
    uint256 constant OFFSET = 1;

    function isWithdrawQuotaInitialized(address token) private view returns (bool) {
        return intradayQuota()[withdrawQuotaKey(token)] != 0;
    }

    function getIntradayQuota(address token) internal view returns (uint256) {
        return intradayQuota()[withdrawQuotaKey(token)] - OFFSET;
    }

    function setIntradayQuota(address token, uint256 value) private {
        intradayQuota()[withdrawQuotaKey(token)] = value + OFFSET;
    }

    /**
        Returns the remaining amount of withdrawal allowed for this day.
        If the daily allowance was not yet set, it is calculated and returned.
     */
    function getRemainingIntradayAllowance(address token) internal view returns (uint256) {
        if (!isWithdrawQuotaInitialized(token)) {
            return calculateIntradayAllowance(token);
        }
        return getIntradayQuota(token);
    }

    /**
        Consumes the intraday allowance for a given token.
        If the allowance was not yet calculated, it is calculated and consumed.
     */
    function consumeWithdrawQuota(address token, uint256 amount) internal {
        uint256 intradayAllowance = getRemainingIntradayAllowance(token);
        require(intradayAllowance >= amount, "EXCEEDS_GLOBAL_WITHDRAW_LIMIT");
        setIntradayQuota(token, intradayAllowance - amount);
    }
}
