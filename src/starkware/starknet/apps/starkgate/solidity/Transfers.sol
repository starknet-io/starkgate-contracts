// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/contracts/libraries/Common.sol";
import "contracts/starkware/contracts/tokens/ERC20/IERC20.sol";

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
        IERC20 erc20_token = IERC20(token);
        uint256 bridgeBalanceBefore = erc20_token.balanceOf(address(this));
        require(bridgeBalanceBefore + amount >= bridgeBalanceBefore, "OVERFLOW");
        bytes memory callData = abi.encodeWithSelector(
            erc20_token.transferFrom.selector,
            sender,
            address(this),
            amount
        );
        token.safeTokenContractCall(callData);
        uint256 bridgeBalanceAfter = erc20_token.balanceOf(address(this));
        // NOLINTNEXTLINE(incorrect-equality): strict equality needed.
        require(bridgeBalanceAfter == bridgeBalanceBefore + amount, "INCORRECT_AMOUNT_TRANSFERRED");
    }

    /*
      Transfers funds from the bridge to recipient.
    */
    function transferOut(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        IERC20 erc20_token = IERC20(token);
        // Make sure we don't accidentally burn funds.
        require(recipient != address(0x0), "INVALID_RECIPIENT");
        uint256 bridgeBalanceBefore = erc20_token.balanceOf(address(this));
        require(bridgeBalanceBefore - amount <= bridgeBalanceBefore, "UNDERFLOW");
        bytes memory callData = abi.encodeWithSelector(
            erc20_token.transfer.selector,
            recipient,
            amount
        );
        token.safeTokenContractCall(callData);
        uint256 bridgeBalanceAfter = erc20_token.balanceOf(address(this));
        // NOLINTNEXTLINE(incorrect-equality): strict equality needed.
        require(bridgeBalanceAfter == bridgeBalanceBefore - amount, "INCORRECT_AMOUNT_TRANSFERRED");
    }
}
