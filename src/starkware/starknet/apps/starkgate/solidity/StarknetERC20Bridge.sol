// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/contracts/libraries/NamedStorage.sol";
import "contracts/starkware/contracts/tokens/ERC20/IERC20.sol";
import "contracts/starkware/starknet/apps/starkgate/solidity/StarknetTokenBridge.sol";
import "contracts/starkware/starknet/apps/starkgate/solidity/Transfers.sol";

contract StarknetERC20Bridge is StarknetTokenBridge {
    function deposit(uint256 amount, uint256 l2Recipient) external {
        require(
            IERC20(bridgedToken()).balanceOf(address(this)) + amount <= maxTotalBalance(),
            "MAX_BALANCE_EXCEEDED"
        );
        Transfers.transferIn(bridgedToken(), msg.sender, amount);
        sendMessage(amount, l2Recipient);
    }

    function withdraw(uint256 amount, address recipient) public override {
        consumeMessage(amount, recipient);
        Transfers.transferOut(bridgedToken(), recipient, amount);
    }
}
