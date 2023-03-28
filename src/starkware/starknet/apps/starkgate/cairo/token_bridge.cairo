%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_lt_felt, assert_not_zero
from starkware.cairo.common.uint256 import (
    Uint256,
    assert_uint256_eq,
    assert_uint256_le,
    uint256_add,
    uint256_check,
    uint256_eq,
)
from starkware.starknet.common.eth_utils import assert_eth_address_range
from starkware.starknet.common.messages import send_message_to_l1
from starkware.starknet.common.syscalls import get_caller_address
from starkware.starknet.std_contracts.ERC20.IERC20 import IERC20
from starkware.starknet.std_contracts.ERC20.mintable_token_interface import IMintableToken
from starkware.starknet.std_contracts.upgradability_proxy.initializable import (
    initialized,
    set_initialized,
)

const WITHDRAW_MESSAGE = 0;
const CONTRACT_IDENTITY = 'STARKGATE';
const CONTRACT_VERSION = 1;

// Storage.

@storage_var
func governor() -> (res: felt) {
}

@storage_var
func l1_bridge() -> (res: felt) {
}

@storage_var
func l2_token() -> (res: felt) {
}

// Events.

// An event that is emitted when set_l1_bridge is called.
// * l1_bridge_address is the new l1 bridge address.
@event
func l1_bridge_set(l1_bridge_address: felt) {
}

// An event that is emitted when set_l2_token is called.
// * l2_token_address is the new l2 token address.
@event
func l2_token_set(l2_token_address: felt) {
}

// An event that is emitted when initiate_withdraw is called.
// * l1_recipient is the l1 recipient address.
// * amount is the amount to withdraw.
// * caller_address is the address from which the call was made.
@event
func withdraw_initiated(l1_recipient: felt, amount: Uint256, caller_address: felt) {
}

// An event that is emitted when handle_deposit is called.
// * account is the recipient address.
// * amount is the amount to deposit.
@event
func deposit_handled(account: felt, amount: Uint256) {
}

// Getters.

@view
func get_governor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    res: felt
) {
    let (res) = governor.read();
    return (res=res);
}

@view
func get_l1_bridge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    res: felt
) {
    let (res) = l1_bridge.read();
    return (res=res);
}

@view
func get_l2_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    res: felt
) {
    let (res) = l2_token.read();
    return (res=res);
}

@view
func get_version() -> (version: felt) {
    return (version=CONTRACT_VERSION);
}

@view
func get_identity() -> (identity: felt) {
    return (identity=CONTRACT_IDENTITY);
}

// Modifiers.

func only_governor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // The call is restricted to the governor.
    let (caller_address) = get_caller_address();
    let (governor_) = get_governor();
    with_attr error_message("GOVERNOR_ONLY") {
        assert caller_address = governor_;
    }
    return ();
}

// Constructor (as initializer).

@external
func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    init_vector_len: felt, init_vector: felt*
) {
    set_initialized();
    // We expect only governor address in the init vector.
    with_attr error_message("ILLEGAL_INIT_SIZE") {
        assert init_vector_len = 1;
    }
    let governor_address = [init_vector];
    with_attr error_message("ZERO_GOVERNOR_ADDRESS") {
        assert_not_zero(governor_address);
    }
    governor.write(value=governor_address);
    return ();
}

// Externals.

@external
func set_l1_bridge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    l1_bridge_address: felt
) {
    // The call is restricted to the governor.
    only_governor();

    // Check l1_bridge isn't already set.
    let (l1_bridge_) = get_l1_bridge();
    with_attr error_message("BRIDGE_ALREADY_INITIALIZED") {
        assert l1_bridge_ = 0;
    }

    // Check new address is valid.
    with_attr error_message("BRIDGE_ADDRESS_OUT_OF_RANGE") {
        assert_eth_address_range(l1_bridge_address);
    }

    // Set new value.
    l1_bridge.write(value=l1_bridge_address);

    l1_bridge_set.emit(l1_bridge_address=l1_bridge_address);
    return ();
}

@external
func set_l2_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    l2_token_address: felt
) {
    // The call is restricted to the governor.
    only_governor();

    // Check l2_token isn't already set.
    let (l2_token_) = get_l2_token();
    with_attr error_message("L2_TOKEN_ALREADY_INITIALIZED") {
        assert l2_token_ = 0;
    }

    with_attr error_message("ZERO_TOKEN_ADDRESS") {
        assert_not_zero(l2_token_address);
    }
    l2_token.write(value=l2_token_address);

    l2_token_set.emit(l2_token_address=l2_token_address);
    return ();
}

@external
func initiate_withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    l1_recipient: felt, amount: Uint256
) {
    alloc_locals;

    // Check recipient address is valid.
    with_attr error_message("RECIPIENT_ADDRESS_OUT_OF_RANGE") {
        assert_eth_address_range(l1_recipient);
    }
    // Check amount is a valid Uint256.
    with_attr error_message("INVALID_AMOUNT") {
        uint256_check(amount);
    }
    // Check amount is not zero.
    with_attr error_message("ZERO_WITHDRAWAL") {
        let (amount_is_zero) = uint256_eq(Uint256(low=0, high=0), amount);
        assert (amount_is_zero) = 0;
    }

    // Check token and bridge addresses are valid.
    let (l1_bridge_) = get_l1_bridge();
    with_attr error_message("UNINITIALIZED_L1_BRIDGE_ADDRESS") {
        assert_not_zero(l1_bridge_);
    }
    let (l2_token_) = get_l2_token();
    with_attr error_message("UNINITIALIZED_TOKEN") {
        assert_not_zero(l2_token_);
    }

    // Call burn on l2_token contract and verify success.
    let (caller_address) = get_caller_address();
    let (local balance_before: Uint256) = IERC20.balanceOf(
        contract_address=l2_token_, account=caller_address
    );
    with_attr error_message("INSUFFICIENT_FUNDS") {
        assert_uint256_le(amount, balance_before);
    }
    IMintableToken.permissionedBurn(
        contract_address=l2_token_, account=caller_address, amount=amount
    );

    let (balance_after: Uint256) = IERC20.balanceOf(
        contract_address=l2_token_, account=caller_address
    );
    let (expected_balance_before: Uint256, carry: felt) = uint256_add(balance_after, amount);
    with_attr error_message("INCORRECT_BALANCE_CHANGE") {
        assert carry = 0;
        assert_uint256_eq(expected_balance_before, balance_before);
    }

    // Send the message.
    let (message_payload: felt*) = alloc();
    assert message_payload[0] = WITHDRAW_MESSAGE;
    assert message_payload[1] = l1_recipient;
    assert message_payload[2] = amount.low;
    assert message_payload[3] = amount.high;

    send_message_to_l1(to_address=l1_bridge_, payload_size=4, payload=message_payload);

    withdraw_initiated.emit(
        l1_recipient=l1_recipient, amount=amount, caller_address=caller_address
    );
    return ();
}

@l1_handler
func handle_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    from_address: felt, account: felt, amount_low: felt, amount_high: felt
) {
    alloc_locals;
    // Check account address is valid.
    with_attr error_message("ZERO_ACCOUNT_ADDRESS") {
        assert_not_zero(account);
    }
    // Check token and bridge addresses are initialized and the handler invoked by the bridge.
    let (l1_bridge_) = get_l1_bridge();
    with_attr error_message("UNINITIALIZED_L1_BRIDGE_ADDRESS") {
        assert_not_zero(l1_bridge_);
    }
    with_attr error_message("EXPECTED_FROM_BRIDGE_ONLY") {
        assert from_address = l1_bridge_;
    }

    let (l2_token_) = get_l2_token();
    with_attr error_message("UNINITIALIZED_TOKEN") {
        assert_not_zero(l2_token_);
    }

    // Call mint on l2_token contract and verify success.
    let amount: Uint256 = cast((low=amount_low, high=amount_high), Uint256);
    with_attr error_message("INVALID_AMOUNT") {
        uint256_check(amount);
    }
    let (local balance_before: Uint256) = IERC20.balanceOf(
        contract_address=l2_token_, account=account
    );
    let (expected_balance_after: Uint256, carry: felt) = uint256_add(balance_before, amount);
    with_attr error_message("OVERFLOW") {
        assert carry = 0;
    }

    IMintableToken.permissionedMint(contract_address=l2_token_, account=account, amount=amount);

    let (balance_after: Uint256) = IERC20.balanceOf(contract_address=l2_token_, account=account);
    with_attr error_message("INCORRECT_BALANCE_CHANGE") {
        assert_uint256_eq(expected_balance_after, balance_after);
    }

    deposit_handled.emit(account=account, amount=amount);
    return ();
}
