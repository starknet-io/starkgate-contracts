// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

uint256 constant DEPOSIT_FEE_GAS = 20000;
uint256 constant DEPLOYMENT_FEE_GAS = 100000;
uint256 constant MIN_FEE_MARGIN = 100000;
uint256 constant MAX_FEE_MARGIN = 10**14;

library Fees {
    function estimateDepositFee() internal view returns (uint256) {
        return DEPOSIT_FEE_GAS * block.basefee;
    }

    function estimateEnrollmentFee() internal view returns (uint256) {
        return DEPLOYMENT_FEE_GAS * block.basefee;
    }

    function checkDepositFee(uint256 feeWei) internal view {
        checkFee(feeWei, estimateDepositFee());
    }

    function checkEnrollmentFee(uint256 feeWei) internal view {
        checkFee(feeWei, estimateEnrollmentFee());
    }

    /*
      The fee should be within margins from the estimated fee:
      max(5, estimate/2 - MIN_FEE_MARGIN) <= fee <= 2*estimate + MAX_FEE_MARGIN.
    */
    function checkFee(uint256 feeWei, uint256 feeEstimate) internal pure {
        uint256 minFee = feeEstimate >> 1;
        minFee = (minFee < MIN_FEE_MARGIN + 5) ? 5 : (minFee - MIN_FEE_MARGIN);
        uint256 maxFee = MAX_FEE_MARGIN + (feeEstimate << 1);
        require(feeWei >= minFee, "INSUFFICIENT_FEE_VALUE");
        require(feeWei <= maxFee, "FEE_VALUE_TOO_HIGH");
    }
}
