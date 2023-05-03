// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/libraries/Addresses.sol";
import "contracts/StarknetTokenBridge.sol";

contract StarknetEthBridge is StarknetTokenBridge {
    using Addresses for address;

    function isTokenContractRequired() internal pure override returns (bool) {
        return false;
    }

    function deposit(uint256 amount, uint256 l2Recipient) public payable override {
        // Make sure msg.value is enough to cover amount. The remaining value is fee.
        require(msg.value >= amount, "INSUFFICIENT_VALUE");
        uint256 fee = msg.value - amount;
        // The msg.value was already credited to this contract. Fee will be passed to StarkNet.
        require(address(this).balance - fee <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        sendMessage(amount, l2Recipient, fee);
    }

    // A backwards compatible deposit function with zero fee.
    function deposit(uint256 l2Recipient) external payable {
        deposit(msg.value, l2Recipient);
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
