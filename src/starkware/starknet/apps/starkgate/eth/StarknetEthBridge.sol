// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/libraries/Addresses.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/StarknetTokenBridge.sol";

contract StarknetEthBridge is StarknetTokenBridge {
    using Addresses for address;

    function deposit(uint256 l2Recipient) external payable {
        // The msg.value in this transaction was already credited to the contract.
        require(address(this).balance <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        sendMessage(msg.value, l2Recipient);
    }

    function withdraw(uint256 amount, address recipient) public override {
        // Make sure we don't accidentally burn funds.
        require(recipient != address(0x0), "INVALID_RECIPIENT");

        // The call to consumeMessage will succeed only if a matching L2->L1 message
        // exists and is ready for consumption.
        consumeMessage(amount, recipient);
        recipient.performEthTransfer(amount);
    }

    function transferOutFunds(uint256 amount, address recipient) internal override {
        recipient.performEthTransfer(amount);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetEthBridge_2022_1";
    }
}
