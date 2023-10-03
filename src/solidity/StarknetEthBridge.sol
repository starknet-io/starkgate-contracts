// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/Addresses.sol";
import "src/solidity/StarknetTokenBridge.sol";

contract StarknetEthBridge is StarknetTokenBridge {
    using Addresses for address;

    address constant ETH = address(0x0);

    function acceptDeposit(
        address, /*token*/
        uint256 amount
    ) internal override returns (uint256) {
        // Make sure msg.value is enough to cover amount. The remaining value is fee.
        require(msg.value >= amount, "INSUFFICIENT_VALUE");
        uint256 fee = msg.value - amount;
        // The msg.value was already credited to this contract. Fee will be passed to Starknet.
        require(address(this).balance - fee <= getMaxTotalBalance(ETH), "MAX_BALANCE_EXCEEDED");
        return fee;
    }

    function transferOutFunds(
        address, /*token*/
        uint256 amount,
        address recipient
    ) internal override {
        recipient.performEthTransfer(amount);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetEthBridge_2022_1";
    }
}
