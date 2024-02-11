%lang starknet

// Import necessary Cairo built-ins and utility functions for handling uint256 operations and assertions.
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.math import assert_nn_le, assert_not_zero
from starkware.cairo.common.uint256 import (
    Uint256,
    uint256_add,
    uint256_check,
    uint256_le,
    uint256_sub,
)

// In Solidity, ERC20 decimals is usually a uint8, but here we set a maximum for safety.
const MAX_DECIMALS = 255;

// Events declaration for ERC20 transfers and approvals.
@event
func Transfer(from_: felt, to: felt, value: Uint256) {
    // Event emitted when tokens are transferred, including minting and burning.
}

@event
func Approval(owner: felt, spender: felt, value: Uint256) {
    // Event emitted when a spender is approved to spend tokens on behalf of an owner.
}

// Storage variable declarations for ERC20 token properties.
@storage_var
func ERC20_name() -> (name: felt) {
    // Stores the token name.
}

@storage_var
func ERC20_symbol() -> (symbol: felt) {
    // Stores the token symbol.
}

@storage_var
func ERC20_decimals() -> (decimals: felt) {
    // Stores the token decimals.
}

@storage_var
func ERC20_total_supply() -> (total_supply: Uint256) {
    // Stores the total token supply.
}

@storage_var
func ERC20_balances(account: felt) -> (balance: Uint256) {
    // Maps an account address to its balance.
}

@storage_var
func ERC20_allowances(owner: felt, spender: felt) -> (allowance: Uint256) {
    // Maps a tuple of owner and spender to the amount of tokens the spender is allowed to use.
}

// Contract initializer sets up the token name, symbol, and decimals.
func ERC20_initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    name: felt, symbol: felt, decimals: felt
) {
    assert_nn_le(decimals, MAX_DECIMALS); // Ensure decimals are within bounds.
    ERC20_name.write(name);
    ERC20_symbol.write(symbol);
    ERC20_decimals.write(decimals);
    return ();
}

// Getter functions for token properties.
@view
func name{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (name: felt) {
    let (name) = ERC20_name.read();
    return (name=name); // Return the token name.
}

@view
func symbol{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (symbol: felt) {
    let (symbol) = ERC20_symbol.read();
    return (symbol=symbol); // Return the token symbol.
}

@view
func decimals{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    decimals: felt
) {
    let (decimals) = ERC20_decimals.read();
    return (decimals=decimals); // Return the token decimals.
}

@view
func totalSupply{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    totalSupply: Uint256
) {
    let (totalSupply: Uint256) = ERC20_total_supply.read();
    return (totalSupply=totalSupply); // Return the total supply.
}

@view
func balanceOf{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(account: felt) -> (
    balance: Uint256
) {
    let (balance: Uint256) = ERC20_balances.read(account=account);
    return (balance=balance); // Return the balance of the specified account.
}

@view
func allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: felt, spender: felt
) -> (remaining: Uint256) {
    let (remaining: Uint256) = ERC20_allowances.read(owner=owner, spender=spender);
    return (remaining=remaining); // Return the remaining allowance.
}

// Internal functions for minting, transferring, approving, and burning tokens follow.
// Minting function adds tokens to an account's balance and increases the total supply.
func ERC20_mint{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: felt, amount: Uint256
) {
    alloc_locals;
    assert_not_zero(recipient); // Ensure the recipient address is not zero.
    uint256_check(amount); // Ensure the amount is a valid Uint256.

    let (balance: Uint256) = ERC20_balances.read(account=recipient);
    let (new_balance: Uint256, _) = uint256_add(balance, amount); // Add amount to recipient's balance.
    ERC20_balances.write(recipient, new_balance);

    let (supply: Uint256) = ERC20_total_supply.read();
    let (new_supply: Uint256, is_overflow) = uint256_add(supply, amount); // Increase total supply.
    assert is_overflow = 0; // Ensure there's no overflow.

    ERC20_total_supply.write(new_supply);
    Transfer.emit(0, recipient, amount); // Emit a transfer event from address 0, indicating minting.
    return ();
}

// Transfer function moves tokens from one account to another.
func ERC20_transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: felt, recipient: felt, amount: Uint256
) {
    alloc_locals;
    assert_not_zero(sender); // Ensure the sender address is not zero.
    assert_not_zero(recipient); // Ensure the recipient address is not zero.
    uint256_check(amount); // Validate the amount is a proper Uint256.

    let (sender_balance: Uint256) = ERC20_balances.read(account=sender);
    let (enough_balance) = uint256_le(amount, sender_balance); // Check sender has enough balance.
    assert_not_zero(enough_balance);

    let (new_sender_balance: Uint256) = uint256_sub(sender_balance, amount); // Subtract amount from sender.
    ERC20_balances.write(sender, new_sender_balance);

    let (recipient_balance: Uint256) = ERC20_balances.read(account=recipient);
    let (new_recipient_balance, _) = uint256_add(recipient_balance, amount); // Add amount to recipient.
    ERC20_balances.write(recipient, new_recipient_balance);

    Transfer.emit(sender, recipient, amount); // Emit a transfer event.
    return ();
}

// Approve function allows a spender to withdraw up to an amount of tokens on behalf of the owner.
func ERC20_approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    caller: felt, spender: felt, amount: Uint256
) {
    assert_not_zero(caller); // Ensure the caller address is not zero.
    assert_not_zero(spender); // Ensure the spender address is not zero.
    uint256_check(amount); // Validate the amount is a proper Uint256.

    ERC20_allowances.write(caller, spender, amount); // Set the allowance.
    Approval.emit(caller, spender, amount); // Emit an approval event.
    return ();
}

// Burning function removes tokens from an account's balance and decreases the total supply.
func ERC20_burn{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    account: felt, amount: Uint256
) {
    alloc_locals;
    assert_not_zero(account); // Ensure the account address is not zero.
    uint256_check(amount); // Ensure the amount is a valid Uint256.

    let (balance: Uint256) = ERC20_balances.read(account);
    let (enough_balance) = uint256_le(amount, balance); // Check account has enough balance.
    assert_not_zero(enough_balance);

    let (new_balance: Uint256) = uint256_sub(balance, amount); // Subtract amount from balance.
    ERC20_balances.write(account, new_balance);

    let (supply: Uint256) = ERC20_total_supply.read();
    let (new_supply: Uint256) = uint256_sub(supply, amount); // Decrease total supply.
    ERC20_total_supply.write(new_supply);

    Transfer.emit(account, 0, amount); // Emit a transfer event to address 0, indicating burning.
    return ();
}
