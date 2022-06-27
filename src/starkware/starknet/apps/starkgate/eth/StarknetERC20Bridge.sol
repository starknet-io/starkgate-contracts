// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/libraries/NamedStorage.sol";
import "contracts/starkware/solidity/tokens/ERC20/IERC20.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/StarknetTokenBridge.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/Transfers.sol";

contract StarknetERC20Bridge is StarknetTokenBridge {
    function deposit(uint256 amount, uint256 l2Recipient) external {
        uint256 currentBalance = IERC20(bridgedToken()).balanceOf(address(this));
        require(currentBalance <= currentBalance + amount, "OVERFLOW");
        require(currentBalance + amount <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        Transfers.transferIn(bridgedToken(), msg.sender, amount);
        sendMessage(amount, l2Recipient);
    }

    function withdraw(uint256 amount, address recipient) public override {
        // The call to consumeMessage will succeed only if a matching L2->L1 message
        // exists and is ready for consumption.
        consumeMessage(amount, recipient);
        Transfers.transferOut(bridgedToken(), recipient, amount);
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
