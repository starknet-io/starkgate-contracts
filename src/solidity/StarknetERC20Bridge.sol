// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/solidity/libraries/Transfers.sol";
import "starkware/solidity/tokens/ERC20/IERC20.sol";
import "src/solidity/StarknetTokenBridge.sol";

contract StarknetERC20Bridge is StarknetTokenBridge {
    function deposit(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata receipt
    ) external payable override {
        uint256 currentBalance = IERC20(bridgedToken()).balanceOf(address(this));
        require(currentBalance <= currentBalance + amount, "OVERFLOW");
        require(currentBalance + amount <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        sendMessage(amount, l2Recipient, receipt, msg.value);
        Transfers.transferIn(bridgedToken(), msg.sender, amount);
    }

    function transferOutFunds(uint256 amount, address recipient) internal override {
        Transfers.transferOut(bridgedToken(), recipient, amount);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetERC20Bridge_2023_1";
    }
}
