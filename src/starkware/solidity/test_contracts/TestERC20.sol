// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/tokens/ERC20/ERC20.sol";

/*
  An ERC20 for testing where anyone can set the balance for everyone.
*/
contract TestERC20 is ERC20 {
    function setBalance(address account, uint256 amount) external {
        _totalSupply -= _balances[account];
        require(_totalSupply <= _totalSupply + amount, "TOTAL_SUPPLY_OVERFLOW");
        _balances[account] = amount;
        _totalSupply += amount;
    }
}
