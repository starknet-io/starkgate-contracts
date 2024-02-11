%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace IERC20 {
    // Returns the name of the token.
    func name() -> (name: felt) {
    }

    // Returns the symbol of the token.
    func symbol() -> (symbol: felt) {
    }

    // Returns the number of decimals the token uses.
    func decimals() -> (decimals: felt) {
    }

    // Returns the total token supply.
    func totalSupply() -> (totalSupply: Uint256) {
    }

    // Returns the balance of the specified account.
    func balanceOf(account: felt) -> (balance: Uint256) {
    }

    // Returns the remaining number of tokens that the spender is allowed to spend on behalf of the owner.
    func allowance(owner: felt, spender: felt) -> (remaining: Uint256) {
    }

    // Transfers a specific amount of tokens to a specified recipient.
    func transfer(recipient: felt, amount: Uint256) -> (success: felt) {
    }

    // Transfers a specific amount of tokens from a sender to a recipient, using the allowance mechanism.
    func transferFrom(sender: felt, recipient: felt, amount: Uint256) -> (success: felt) {
    }

    // Approves a spender to spend a specific amount of tokens on behalf of the message sender.
    func approve(spender: felt, amount: Uint256) -> (success: felt) {
    }
}
