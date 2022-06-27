// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/libraries/Addresses.sol";
import "contracts/starkware/solidity/tokens/ERC20/IERC20.sol";

library Transfers {
    using Addresses for address;

    /*
      Transfers funds from sender to the bridge.
    */
    function transferIn(
        address token,
        address sender,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        IERC20 erc20Token = IERC20(token);
        uint256 bridgeBalanceBefore = erc20Token.balanceOf(address(this));
        uint256 expectedAfter = bridgeBalanceBefore + amount;
        require(expectedAfter >= bridgeBalanceBefore, "OVERFLOW");

        bytes memory callData = abi.encodeWithSelector(
            erc20Token.transferFrom.selector,
            sender,
            address(this),
            amount
        );
        token.safeTokenContractCall(callData);

        uint256 bridgeBalanceAfter = erc20Token.balanceOf(address(this));
        require(bridgeBalanceAfter == expectedAfter, "INCORRECT_AMOUNT_TRANSFERRED");
    }

    /*
      Transfers funds from the bridge to recipient.
    */
    function transferOut(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        // Make sure we don't accidentally burn funds.
        require(recipient != address(0x0), "INVALID_RECIPIENT");
        if (amount == 0) return;
        IERC20 erc20Token = IERC20(token);
        uint256 bridgeBalanceBefore = erc20Token.balanceOf(address(this));
        uint256 expectedAfter = bridgeBalanceBefore - amount;
        require(expectedAfter <= bridgeBalanceBefore, "UNDERFLOW");

        bytes memory callData = abi.encodeWithSelector(
            erc20Token.transfer.selector,
            recipient,
            amount
        );
        token.safeTokenContractCall(callData);

        uint256 bridgeBalanceAfter = erc20Token.balanceOf(address(this));
        require(bridgeBalanceAfter == expectedAfter, "INCORRECT_AMOUNT_TRANSFERRED");
    }
}
