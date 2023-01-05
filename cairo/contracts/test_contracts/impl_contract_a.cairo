%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starknet.std_contracts.upgradability_proxy.initializable import (
    initialized,
    set_initialized,
)

@storage_var
func stored_value() -> (value : felt) {
}

@view
func get_value{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    value : felt
) {
    let (value) = stored_value.read();
    return (value,);
}

@view
func get_magic_number{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    value : felt
) {
    return (0x0a,);
}

@external
func set_value{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(value : felt) {
    // Set new value.
    stored_value.write(value=value);
    return ();
}

// This implementation expects 2 felt and assign their sum into the stored_value.
@external
func initialize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    init_vector_len : felt, init_vector : felt*
) {
    set_initialized();
    with_attr error_message("ILLEGAL_INIT_SIZE") {
        assert init_vector_len = 2;
    }
    let value_1 = [init_vector];
    let value_2 = [init_vector + 1];
    stored_value.write(value=value_1 + value_2);
    return ();
}
