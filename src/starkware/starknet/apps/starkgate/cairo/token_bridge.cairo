%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_lt_felt, assert_not_zero
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.messages import send_message_to_l1
from starkware.starknet.common.syscalls import get_caller_address
from starkware.starknet.std_contracts.ERC20.mintable_token_interface import IMintableToken
from starkware.starknet.std_contracts.upgradability_proxy.initializable import (
    initialized,
    set_initialized,
)

const WITHDRAW_MESSAGE = 0
const ETH_ADDRESS_BOUND = 2 ** 160
const CONTRACT_IDENTITY = 'STARKGATE'
const CONTRACT_VERSION = 1

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

# Events.

# An event that is emitted when set_l1_bridge is called.
# * l1_bridge_address is the new l1 bridge address.
@event
func l1_bridge_set(l1_bridge_address : felt):
end

# An event that is emitted when set_l2_token is called.
# * l2_token_address is the new l2 token address.
@event
func l2_token_set(l2_token_address : felt):
end

# An event that is emitted when initiate_withdraw is called.
# * l1_recipient is the l1 recipient address.
# * amount is the amount to withdraw.
# * caller_address is the address from which the call was made.
@event
func withdraw_initiated(l1_recipient : felt, amount : Uint256, caller_address : felt):
end

# An event that is emitted when handle_deposit is called.
# * account is the recipient address.
# * amount is the amount to deposit.
@event
func deposit_handled(account : felt, amount : Uint256):
end

# Getters.

@view
func get_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    res : felt
):
    let (res) = governor.read()
    return (res)
end

@view
func get_l1_bridge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    res : felt
):
    let (res) = l1_bridge.read()
    return (res)
end

@view
func get_l2_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    res : felt
):
    let (res) = l2_token.read()
    return (res)
end

@view
func get_version() -> (version : felt):
    return (version=CONTRACT_VERSION)
end

@view
func get_identity() -> (identity : felt):
    return (identity=CONTRACT_IDENTITY)
end

# Constructor (as initializer).

@external
func initialize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    init_vector_len : felt, init_vector : felt*
):
    set_initialized()
    # We expect only governor address in the init vector.
    with_attr error_message("ILLEGAL_INIT_SIZE"):
        assert init_vector_len = 1
    end
    let governor_address = [init_vector]
    with_attr error_message("ZERO_GOVERNOR_ADDRESS"):
        assert_not_zero(governor_address)
    end
    governor.write(value=governor_address)
    return ()
end

# Externals.

@external
func set_l1_bridge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    l1_bridge_address : felt
):
    # The call is restricted to the governor.
    let (caller_address) = get_caller_address()
    let (governor_) = get_governor()
    with_attr error_message("GOVERNOR_ONLY"):
        assert caller_address = governor_
    end

    # Check l1_bridge isn't already set.
    let (l1_bridge_) = get_l1_bridge()
    with_attr error_message("BRIDGE_ALREADY_INITIALIZED"):
        assert l1_bridge_ = 0
    end

    # Check new address is valid.
    with_attr error_message("BRIDGE_ADDRESS_OUT_OF_RANGE"):
        assert_lt_felt(l1_bridge_address, ETH_ADDRESS_BOUND)
    end
    with_attr error_message("ZERO_BRIDGE_ADDRESS"):
        assert_not_zero(l1_bridge_address)
    end

    # Set new value.
    l1_bridge.write(value=l1_bridge_address)

    l1_bridge_set.emit(l1_bridge_address=l1_bridge_address)
    return ()
end

@external
func set_l2_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    l2_token_address : felt
):
    # The call is restricted to the governor.
    let (caller_address) = get_caller_address()
    let (governor_) = get_governor()
    with_attr error_message("GOVERNOR_ONLY"):
        assert caller_address = governor_
    end

    # Check l2_token isn't already set.
    let (l2_token_) = get_l2_token()
    with_attr error_message("L2_TOKEN_ALREADY_INITIALIZED"):
        assert l2_token_ = 0
    end

    with_attr error_message("ZERO_TOKEN_ADDRESS"):
        assert_not_zero(l2_token_address)
    end
    l2_token.write(value=l2_token_address)

    l2_token_set.emit(l2_token_address=l2_token_address)
    return ()
end

@external
func initiate_withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    l1_recipient : felt, amount : Uint256
):
    # The amount is validated (i.e. amount.low, amount.high < 2**128) by an inner call to
    # IMintableToken permissionedBurn function.

    # Check address is valid.
    with_attr error_message("RECIPIENT_ADDRESS_OUT_OF_RANGE"):
        assert_lt_felt(l1_recipient, ETH_ADDRESS_BOUND)
    end

    # Call burn on l2_token contract.
    let (caller_address) = get_caller_address()
    let (l2_token_) = get_l2_token()
    with_attr error_message("UNINITIALIZED_TOKEN"):
        assert_not_zero(l2_token_)
    end
    IMintableToken.permissionedBurn(
        contract_address=l2_token_, account=caller_address, amount=amount
    )

    # Send the message.
    let (message_payload : felt*) = alloc()
    assert message_payload[0] = WITHDRAW_MESSAGE
    assert message_payload[1] = l1_recipient
    assert message_payload[2] = amount.low
    assert message_payload[3] = amount.high
    let (to_address) = get_l1_bridge()

    # Check address is valid.
    with_attr error_message("TO_ADDRESS_OUT_OF_RANGE"):
        assert_lt_felt(to_address, ETH_ADDRESS_BOUND)
    end
    with_attr error_message("ZERO_ADDRESS"):
        assert_not_zero(to_address)
    end
    send_message_to_l1(to_address=to_address, payload_size=4, payload=message_payload)

    withdraw_initiated.emit(l1_recipient=l1_recipient, amount=amount, caller_address=caller_address)
    return ()
end

@l1_handler
func handle_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    from_address : felt, account : felt, amount_low : felt, amount_high : felt
):
    # The amount is validated (i.e. amount_low, amount_high < 2**128) by an inner call to
    # IMintableToken permissionedMint function.

    let (expected_from_address) = get_l1_bridge()
    with_attr error_message("EXPECTED_FROM_BRIDGE_ONLY"):
        assert from_address = expected_from_address
    end
    let amount : Uint256 = cast((low=amount_low, high=amount_high), Uint256)

    # Call mint on l2_token contract.
    let (l2_token_) = get_l2_token()
    with_attr error_message("UNINITIALIZED_TOKEN"):
        assert_not_zero(l2_token_)
    end
    IMintableToken.permissionedMint(contract_address=l2_token_, account=account, amount=amount)

    deposit_handled.emit(account=account, amount=amount)
    return ()
end
