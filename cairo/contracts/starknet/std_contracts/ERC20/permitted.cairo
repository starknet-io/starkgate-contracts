%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

@storage_var
func permitted_minter() -> (res: felt) {
}

// Constructor.

func permitted_initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    minter_address: felt
) {
    assert_not_zero(minter_address);
    permitted_minter.write(minter_address);
    return ();
}

// Getters.

@view
func permittedMinter{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    minter: felt
) {
    let (minter) = permitted_minter.read();
    return (minter,);
}

// Internals.

func permitted_minter_only{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (caller_address) = get_caller_address();
    let (permitted_address) = permittedMinter();
    assert_not_zero(permitted_address);
    assert caller_address = permitted_address;
    return ();
}
