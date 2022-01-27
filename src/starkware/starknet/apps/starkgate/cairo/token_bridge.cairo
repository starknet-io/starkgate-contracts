%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_lt_felt, assert_not_zero
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.apps.starkgate.cairo.mintable_token_interface import IMintableToken
from starkware.starknet.common.messages import send_message_to_l1
from starkware.starknet.common.syscalls import get_caller_address

const WITHDRAW_MESSAGE = 0
const ETH_ADDRESS_BOUND = 2 ** 160

# Storage.

@storage_var
func governor() -> (res : felt):
end

@storage_var
func l1_bridge() -> (res : felt):
end

@storage_var
func l2_token() -> (res : felt):
end

# Constructor.

# To finish the init you have to initialize the L2 token contract and the L1 bridge contract.
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        governor_address : felt):
    assert_not_zero(governor_address)
    governor.write(value=governor_address)
    return ()
end

# Getters.

@view
func get_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        res : felt):
    let (res) = governor.read()
    return (res)
end

@view
func get_l1_bridge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        res : felt):
    let (res) = l1_bridge.read()
    return (res)
end

@view
func get_l2_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        res : felt):
    let (res) = l2_token.read()
    return (res)
end

# Externals.

@external
func set_l1_bridge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        l1_bridge_address : felt):
    # The call is restricted to the governor.
    let (caller_address) = get_caller_address()
    let (governor_) = get_governor()
    assert caller_address = governor_

    # Check l1_bridge isn't already set.
    let (l1_bridge_) = get_l1_bridge()
    assert l1_bridge_ = 0

    # Check new address is valid.
    assert_lt_felt(l1_bridge_address, ETH_ADDRESS_BOUND)
    assert_not_zero(l1_bridge_address)

    # Set new value.
    l1_bridge.write(value=l1_bridge_address)
    return ()
end

@external
func set_l2_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        l2_token_address : felt):
    # The call is restricted to the governor.
    let (caller_address) = get_caller_address()
    let (governor_) = get_governor()
    assert caller_address = governor_

    # Check l2_token isn't already set.
    let (l2_token_) = get_l2_token()
    assert l2_token_ = 0

    assert_not_zero(l2_token_address)
    l2_token.write(value=l2_token_address)
    return ()
end

@external
func initiate_withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        l1_recipient : felt, amount : Uint256):
    # The amount is validated (i.e. amount.low, amount.high < 2**128) by an inner call to
    # IMintableToken permissionedBurn function.

    # Check address is valid.
    assert_lt_felt(l1_recipient, ETH_ADDRESS_BOUND)

    # Call burn on l2_token contract.
    let (caller_address) = get_caller_address()
    let (l2_token_) = get_l2_token()
    assert_not_zero(l2_token_)
    IMintableToken.permissionedBurn(
        contract_address=l2_token_, account=caller_address, amount=amount)

    # Send the message.
    let (message_payload : felt*) = alloc()
    assert message_payload[0] = WITHDRAW_MESSAGE
    assert message_payload[1] = l1_recipient
    assert message_payload[2] = amount.low
    assert message_payload[3] = amount.high
    let (to_address) = get_l1_bridge()

    # Check address is valid.
    assert_lt_felt(to_address, ETH_ADDRESS_BOUND)
    assert_not_zero(to_address)
    send_message_to_l1(to_address=to_address, payload_size=4, payload=message_payload)

    return ()
end

@l1_handler
func handle_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        from_address : felt, account : felt, amount_low : felt, amount_high : felt):
    # The amount is validated (i.e. amount_low, amount_high < 2**128) by an inner call to
    # IMintableToken permissionedMint function.

    let (expected_from_address) = get_l1_bridge()
    assert from_address = expected_from_address
    let amount : Uint256 = cast((low=amount_low, high=amount_high), Uint256)

    # Call mint on l2_token contract.
    let (l2_token_) = get_l2_token()
    assert_not_zero(l2_token_)
    IMintableToken.permissionedMint(contract_address=l2_token_, account=account, amount=amount)
    return ()
end
