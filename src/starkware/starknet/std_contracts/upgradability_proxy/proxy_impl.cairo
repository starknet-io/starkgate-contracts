%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash_state import (
    hash_finalize,
    hash_init,
    hash_update,
    hash_update_single,
)
from starkware.cairo.common.math import assert_le, assert_not_zero
from starkware.starknet.common.syscalls import get_block_timestamp
from starkware.starknet.std_contracts.upgradability_proxy.finalizable import finalize, not_finalized
from starkware.starknet.std_contracts.upgradability_proxy.governance import only_governor
from starkware.starknet.std_contracts.upgradability_proxy.Initializable_interface import (
    ExternalInitializer,
    Initializable,
)

@storage_var
func upgrade_delay() -> (delay_seconds : felt):
end

@storage_var
func impl_activation_time(key : felt) -> (ready_time : felt):
end

@storage_var
func class_hash() -> (hash : felt):
end

# Emitted upon adding an implementation.
@event
func implementation_added(
    implementation_hash : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
):
end

# Emitted when an implementation is removed.
@event
func implementation_removed(
    implementation_hash : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
):
end

# Emitted upon upgrading to an implementation.
@event
func implementation_upgraded(
    implementation_hash : felt, eic_hash : felt, init_vector_len : felt, init_vector : felt*
):
end

# Emitted upon implementation finalization.
@event
func implementation_finalized(implementation_hash : felt):
end

@view
func implementation{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    implementation_hash_ : felt
):
    let (implementation_hash_) = class_hash.read()
    return (implementation_hash_)
end

@view
func implementation_time{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    implementation_hash_ : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
) -> (time : felt):
    let (implementation_key) = calc_impl_key(
        implementation_hash_, eic_hash, init_vector_len, init_vector, final
    )
    let (time) = impl_activation_time.read(implementation_key)
    return (time=time)
end

@external
func add_implementation{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    implementation_hash_ : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
):
    alloc_locals
    only_governor()

    # Prevent adding a zero_address implementation.
    with_attr error_message("NOT_AN_IMPLEMENTATION"):
        assert_not_zero(implementation_hash_)
    end

    let (now_) = get_block_timestamp()
    let (upgrade_timelock) = upgrade_delay.read()
    let (implementation_key) = calc_impl_key(
        implementation_hash_, eic_hash, init_vector_len, init_vector, final
    )
    impl_activation_time.write(implementation_key, now_ + upgrade_timelock)

    implementation_added.emit(
        implementation_hash=implementation_hash_,
        eic_hash=eic_hash,
        init_vector_len=init_vector_len,
        init_vector=init_vector,
        final=final,
    )
    return ()
end

@external
func remove_implementation{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    implementation_hash_ : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
):
    alloc_locals
    only_governor()
    let (implementation_key) = calc_impl_key(
        implementation_hash_, eic_hash, init_vector_len, init_vector, final
    )
    let (time) = impl_activation_time.read(implementation_key)

    # Quiet success if activation time is 0 (i.e. not added).
    if time == 0:
        return ()
    end

    impl_activation_time.write(implementation_key, 0)
    implementation_removed.emit(
        implementation_hash=implementation_hash_,
        eic_hash=eic_hash,
        init_vector_len=init_vector_len,
        init_vector=init_vector,
        final=final,
    )
    return ()
end

@external
func upgrade_to{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    implementation_hash_ : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
):
    # Input is as following:
    # 1. implementation_hash - the class hash of the implementation contract.
    # 2. eic_hash - The EIC (External Initialization Contract) class hash. Zero if no EIC used.
    # 3. init_vector - initialization vector to be passed to the initializer function.
    # 4. final - If TRUE - we set the implementation as finalized.
    #
    # Initialization flow:
    # The flow depends on content of eic_hash argument.
    # a. If eic_hash == 0:
    #    The init_vector is passed to the implementation's initialize function when applicable
    #    (i.e. if not already initialized).
    # b. If eic_hash != 0:
    #    Implementation's initialize function is skipped.
    #    The init_vector is passed to the eic_initialize function of the EIC.
    #    The eic_initialize (library_call) is performed, whether the contract is initialized or not
    #    i.e. EIC can perform initial init, or post init reconfiguration.
    alloc_locals
    only_governor()
    not_finalized()
    let (local now_) = get_block_timestamp()
    let (implementation_key) = calc_impl_key(
        implementation_hash_, eic_hash, init_vector_len, init_vector, final
    )
    let (local activation_time) = impl_activation_time.read(implementation_key)

    # If activation time == 0
    # it means that this implementation & init vector combination was not added.
    with_attr error_message("UNKNOWN_IMPLEMENTATION"):
        assert_not_zero(activation_time)
    end

    # If this is the first implementation (i.e. current_impl == 0) - we don't enforce timelock.
    let (local current_impl) = implementation()
    if current_impl != 0:
        with_attr error_message("NOT_ENABLED_YET"):
            assert_le(activation_time, now_)
        end
        tempvar range_check_ptr = range_check_ptr
    else:
        tempvar range_check_ptr = range_check_ptr
    end

    # Set implementation class_hash.
    set_implementation_hash(implementation_hash_)

    # We emit now so that finalize emit last (if it does).
    implementation_upgraded.emit(
        implementation_hash=implementation_hash_,
        eic_hash=eic_hash,
        init_vector_len=init_vector_len,
        init_vector=init_vector,
    )
    process_final_flag(final_flag=final, implementation_hash_=implementation_hash_)

    # Finally - delegate call initialzie/eic_initialize if applicable.

    # EIC path - If eic class_hash is not zero.
    # Calling eic_initialize and NOT continuing to implementation initializer.
    if eic_hash != 0:
        ExternalInitializer.library_call_eic_initialize(
            class_hash=eic_hash, init_vector_len=init_vector_len, init_vector=init_vector
        )
        return ()
    end

    # NON-EIC path.
    # If not already initialized, call initialize on the implementation.
    let (initialized_ : felt) = Initializable.library_call_initialized(
        class_hash=implementation_hash_
    )
    if initialized_ == FALSE:
        Initializable.library_call_initialize(
            class_hash=implementation_hash_,
            init_vector_len=init_vector_len,
            init_vector=init_vector,
        )
        return ()
    else:
        return ()
    end
end

@external
func initialize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    init_vector_len : felt, init_vector : felt*
):
    with_attr error_message("DIRECT_CALL_PROHIBITED"):
        assert 0 = 1
    end
    return ()
end

func process_final_flag{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    final_flag : felt, implementation_hash_ : felt
):
    if final_flag == FALSE:
        return ()
    else:
        finalize()
        implementation_finalized.emit(implementation_hash=implementation_hash_)
        return ()
    end
end

func set_implementation_hash{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    class_hash_ : felt
):
    only_governor()
    class_hash.write(value=class_hash_)
    return ()
end

func calc_impl_key{pedersen_ptr : HashBuiltin*}(
    implementation_hash_ : felt,
    eic_hash : felt,
    init_vector_len : felt,
    init_vector : felt*,
    final : felt,
) -> (res : felt):
    alloc_locals
    let hash_ptr = pedersen_ptr
    with hash_ptr:
        let (hash_state_ptr) = hash_init()
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, implementation_hash_)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, eic_hash)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, init_vector_len)
        let (hash_state_ptr) = hash_update(hash_state_ptr, init_vector, init_vector_len)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, final)
        let (res) = hash_finalize(hash_state_ptr)
        let pedersen_ptr = hash_ptr
        return (res=res)
    end
end
