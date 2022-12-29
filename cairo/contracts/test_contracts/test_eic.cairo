%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_contract_address
from test_contracts.impl_contract_a import stored_value
from starknet.std_contracts.upgradability_proxy.initializable import set_initialized
from starknet.std_contracts.upgradability_proxy.Initializable_interface import (
    Initializable,
)

@event
func external_initialize(init_vector_len : felt, init_vector : felt*) {
}

@external
func eic_initialize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    init_vector_len : felt, init_vector : felt*
) {
    alloc_locals;
    with_attr error_message("ILLEGAL_EIC_INIT_SIZE") {
        assert init_vector_len = 1;
    }
    let value_ = [init_vector];
    let (current_value) = stored_value.read();
    stored_value.write(value=current_value + value_);
    external_initialize.emit(init_vector_len=init_vector_len, init_vector=init_vector);

    let (this_ : felt) = get_contract_address();
    let (initialized_ : felt) = Initializable.initialized(contract_address=this_);
    if (initialized_ == 0) {
        set_initialized();
        return ();
    } else {
        return ();
    }
}
