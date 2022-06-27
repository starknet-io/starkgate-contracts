%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_equal, assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

@storage_var
func governance_initialized() -> (initialized : felt):
end

@storage_var
func governors(account : felt) -> (active_governor : felt):
end

@storage_var
func candidates(account : felt) -> (governance_candidate : felt):
end

# Emitted upon nomination of a new governor.
@event
func governor_nominated(new_governor_nominee : felt, nominated_by : felt):
end

# Emitted upon cancellation of a new govoernor nomination.
@event
func nomination_cancelled(cancelled_nominee : felt, cancelled_by : felt):
end

# Emitted upon govoernor removal.
@event
func governor_removed(removed_governor : felt, removed_by : felt):
end

# Emitted upon a new governor accepting governance.
@event
func governance_accepted(new_governor : felt):
end

@view
func is_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt
) -> (is_governor_ : felt):
    let (is_governor_) = governors.read(account=account)
    return (is_governor_)
end

@external
func init_governance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (already_init : felt) = governance_initialized.read()
    with_attr error_message("ALREADY_INITIALIZED"):
        assert already_init = FALSE
    end
    let (caller : felt) = get_caller_address()

    # Prevent nomination of zero address.
    with_attr error_message("ZERO_ADDRESS"):
        assert_not_zero(caller)
    end
    governance_initialized.write(TRUE)
    governors.write(account=caller, value=TRUE)
    governor_nominated.emit(new_governor_nominee=caller, nominated_by=caller)
    governance_accepted.emit(new_governor=caller)
    return ()
end

@external
func nominate_new_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    nominee : felt
):
    only_governor()

    # Check that the nominee is not already a governor.
    let (is_governor_) = is_governor(nominee)
    with_attr error_message("ALREADY_GOVERNOR"):
        assert is_governor_ = FALSE
    end

    # Prevent nomination of zero address.
    with_attr error_message("ZERO_ADDRESS"):
        assert_not_zero(nominee)
    end

    # Set the nominee as a candidate.
    candidates.write(account=nominee, value=TRUE)
    let (caller : felt) = get_caller_address()
    governor_nominated.emit(new_governor_nominee=nominee, nominated_by=caller)
    return ()
end

@external
func cancel_nomination{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    cancelee : felt
):
    only_governor()

    # Quietly exit if not a candidate.
    let (is_candidate) = candidates.read(account=cancelee)
    if is_candidate == FALSE:
        return ()
    end

    # Clear candidate flag and emit event.
    candidates.write(account=cancelee, value=FALSE)
    let (caller : felt) = get_caller_address()
    nomination_cancelled.emit(cancelled_nominee=cancelee, cancelled_by=caller)
    return ()
end

@external
func remove_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    removee : felt
):
    only_governor()

    let (is_governor_ : felt) = is_governor(removee)
    with_attr error_message("NOT_A_GOVERNOR"):
        assert_not_zero(is_governor_)
    end

    let (caller : felt) = get_caller_address()
    with_attr error_message("CANNOT_SELF_REMOVE"):
        assert_not_equal(caller, removee)
    end

    governors.write(account=removee, value=FALSE)
    governor_removed.emit(removed_governor=removee, removed_by=caller)
    return ()
end

@external
func accept_governance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (caller : felt) = get_caller_address()

    # Assert that the caller is a candidate.
    let (is_candidate : felt) = candidates.read(account=caller)
    with_attr error_message("NOT_A_GOVERNANCE_CANDIDATE"):
        assert_not_zero(is_candidate)
    end

    # Clear candidate flag, and set governor flag.
    candidates.write(account=caller, value=FALSE)
    governors.write(account=caller, value=TRUE)
    governance_accepted.emit(new_governor=caller)
    return ()
end

func only_governor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (caller) = get_caller_address()
    let (is_governor_) = is_governor(caller)
    with_attr error_message("ONLY_GOVERNOR"):
        assert_not_zero(is_governor_)
    end
    return ()
end
