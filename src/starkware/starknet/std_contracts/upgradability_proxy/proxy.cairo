%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import library_call, library_call_l1_handler
from starkware.starknet.std_contracts.upgradability_proxy.finalizable import finalized
from starkware.starknet.std_contracts.upgradability_proxy.governance import (
    accept_governance,
    cancel_nomination,
    init_governance,
    is_governor,
    nominate_new_governor,
    only_governor,
    remove_governor,
)
from starkware.starknet.std_contracts.upgradability_proxy.proxy_impl import (
    add_implementation,
    implementation,
    remove_implementation,
    upgrade_delay,
    upgrade_to,
)

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    upgrade_delay_seconds : felt
):
    upgrade_delay.write(value=upgrade_delay_seconds)
    return ()
end

@external
@raw_input
@raw_output
func __default__{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    selector : felt, calldata_size : felt, calldata : felt*
) -> (retdata_size : felt, retdata : felt*):
    let (class_hash_) = implementation()

    let (retdata_size : felt, retdata : felt*) = library_call(
        class_hash=class_hash_,
        function_selector=selector,
        calldata_size=calldata_size,
        calldata=calldata,
    )
    return (retdata_size=retdata_size, retdata=retdata)
end

@l1_handler
@raw_input
func __l1_default__{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    selector : felt, calldata_size : felt, calldata : felt*
):
    let (class_hash_) = implementation()

    library_call_l1_handler(
        class_hash=class_hash_,
        function_selector=selector,
        calldata_size=calldata_size,
        calldata=calldata,
    )
    return ()
end
