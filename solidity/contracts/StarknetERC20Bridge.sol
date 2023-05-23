// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "./libraries/NamedStorage.sol";
import "./external/tokens/ERC20/IERC20.sol";
import "./StarknetTokenBridge.sol";
import "./Transfers.sol";

contract StarknetERC20Bridge is StarknetTokenBridge {
    function deposit(uint256 amount, uint256 l2Recipient) external payable override {
        uint256 currentBalance = IERC20(bridgedToken()).balanceOf(address(this));
        require(currentBalance <= currentBalance + amount, "OVERFLOW");
        require(currentBalance + amount <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        sendMessage(amount, l2Recipient, msg.value);
        Transfers.transferIn(bridgedToken(), msg.sender, amount);
    }

    function transferOutFunds(uint256 amount, address recipient) internal override {
        Transfers.transferOut(bridgedToken(), recipient, amount);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetERC20Bridge_2022_1";
    }
}
