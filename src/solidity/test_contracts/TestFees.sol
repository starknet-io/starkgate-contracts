// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

import "src/solidity/Fees.sol";

contract TestFees is Fees {
    function estimateDepositFeeWei() external pure returns (uint256) {
        return Fees.estimateDepositFee();
    }

    function estimateEnrollmentFeeWei() external pure returns (uint256) {
        return Fees.estimateEnrollmentFee();
    }

    function testCheckFee(uint256 feeWei) external view {
        Fees.checkFee(feeWei);
    }
}
