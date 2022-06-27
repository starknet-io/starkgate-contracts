import asyncio
import copy

import pytest

from starkware.starknet.std_contracts.upgradability_proxy.contracts import proxy_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.test_contracts import (
    contract_a_class,
    contract_b_class,
    test_eic_class,
)
from starkware.starknet.std_contracts.upgradability_proxy.test_utils import (
    advance_time,
    assert_events_equal,
    create_event_object,
    starknet_time,
)
from starkware.starknet.testing.contract import DeclaredClass, StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

IMPLEMENTATION_ADDED_EVENT = "implementation_added"
IMPLEMENTATION_REMOVED_EVENT = "implementation_removed"
IMPLEMENTATION_UPGRADED_EVENT = "implementation_upgraded"
IMPLEMENTATION_FINALIZED_EVENT = "implementation_finalized"


FINAL = True
NOT_FINAL = False

magic_number_a = 0x0A
magic_number_b = 0x0B
default_delay = 20
NO_EIC = 0


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session")
def gov() -> int:
    return 31415926535


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    starknet = await Starknet.empty()
    # We want to start with a non-zero block/time (this would fail tests).
    advance_time(starknet=starknet, block_time_diff=1, block_num_diff=1)
    return starknet


@pytest.fixture(scope="session")
async def session_proxy_contract(session_starknet: Starknet) -> StarknetContract:
    return await session_starknet.deploy(
        constructor_calldata=[default_delay], contract_class=proxy_contract_class
    )


@pytest.fixture(scope="session")
async def declared_contract_a(session_starknet: Starknet) -> DeclaredClass:
    return await session_starknet.declare(contract_class=contract_a_class)


@pytest.fixture(scope="session")
async def deployed_contract_a(session_starknet: Starknet) -> StarknetContract:
    return await session_starknet.deploy(constructor_calldata=[], contract_class=contract_a_class)


@pytest.fixture(scope="session")
async def declared_contract_b(session_starknet: Starknet) -> DeclaredClass:
    return await session_starknet.declare(contract_class=contract_b_class)


@pytest.fixture(scope="session")
async def deployed_contract_b(session_starknet: Starknet) -> StarknetContract:
    return await session_starknet.deploy(constructor_calldata=[], contract_class=contract_b_class)


@pytest.fixture(scope="session")
async def declared_eic_impl(session_starknet: Starknet) -> DeclaredClass:
    return await session_starknet.declare(contract_class=test_eic_class)


@pytest.fixture
async def starknet(session_starknet: Starknet) -> Starknet:
    return copy.deepcopy(session_starknet)


@pytest.fixture
async def proxy_contract(
    starknet: Starknet, session_proxy_contract: StarknetContract, gov: int
) -> StarknetContract:
    assert proxy_contract_class.abi is not None
    proxy = StarknetContract(
        state=starknet.state,
        abi=proxy_contract_class.abi,
        contract_address=session_proxy_contract.contract_address,
        deploy_execution_info=session_proxy_contract.deploy_execution_info,
    )
    await proxy.init_governance().invoke(caller_address=gov)
    return proxy


@pytest.fixture
async def wrapped_impl(starknet: Starknet, proxy_contract: StarknetContract) -> StarknetContract:
    assert contract_a_class.abi is not None
    return StarknetContract(
        state=starknet.state,
        abi=contract_a_class.abi,
        contract_address=proxy_contract.contract_address,
        deploy_execution_info=proxy_contract.deploy_execution_info,
    )


@pytest.mark.asyncio
async def test_initial_empty_implementation(proxy_contract: StarknetContract) -> None:
    execution_info = await proxy_contract.implementation().call()
    assert execution_info.result == (0,)


@pytest.mark.asyncio
async def test_impl_a_standalone(deployed_contract_a: StarknetContract) -> None:
    test_value = 0xAAAA
    await impl_standalone_test(
        contract=deployed_contract_a, test_value=test_value, magic_number=magic_number_a
    )


@pytest.mark.asyncio
async def test_impl_b_standalone(deployed_contract_b: StarknetContract) -> None:
    test_value = 0xBBBB
    await impl_standalone_test(
        contract=deployed_contract_b, test_value=test_value, magic_number=magic_number_b
    )


async def impl_standalone_test(
    contract: StarknetContract, test_value: int, magic_number: int
) -> None:
    execution_info = await contract.get_value().call()
    assert execution_info.result == (0,)

    await contract.set_value(test_value).invoke()
    execution_info = await contract.get_value().call()
    assert execution_info.result == (test_value,)

    execution_info = await contract.get_magic_number().call()
    assert execution_info.result == (magic_number,)


@pytest.mark.asyncio
async def test_initializable(deployed_contract_a: StarknetContract) -> None:
    init_vec = [4, 5]

    # Initialized flag is clear.
    assert (await deployed_contract_a.initialized().call()).result[0] == 0

    # Try to init with a bad init data.
    # We expect to fail, and that the initialized flag remains clear.
    with pytest.raises(StarkException, match="ILLEGAL_INIT_SIZE"):
        await deployed_contract_a.initialize([]).invoke()
    assert (await deployed_contract_a.initialized().call()).result[0] == 0

    # Initialize successfully.
    await deployed_contract_a.initialize(init_vec).invoke()
    # Initialized flag is now set.
    assert (await deployed_contract_a.initialized().call()).result[0] == 1

    with pytest.raises(StarkException, match="ALREADY_INITIALIZED"):
        await deployed_contract_a.initialize(init_vec).call()
    with pytest.raises(StarkException, match="ALREADY_INITIALIZED"):
        await deployed_contract_a.initialize([]).call()


@pytest.mark.asyncio
async def test_impl_wrapping(
    starknet: Starknet,
    proxy_contract: StarknetContract,
    wrapped_impl: StarknetContract,
    declared_contract_a: StarknetContract,
    declared_contract_b: StarknetContract,
    gov: int,
) -> None:
    """
    Tests assigning impl to proxy, and switching of one.
    """
    await proxy_contract.add_implementation(
        declared_contract_a.class_hash, NO_EIC, [0], NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    # The concrete impl awaits 2 elements. not zero.
    with pytest.raises(StarkException, match="ILLEGAL_INIT_SIZE"):
        await proxy_contract.upgrade_to(
            declared_contract_a.class_hash, NO_EIC, [0], NOT_FINAL
        ).invoke(caller_address=gov)

    await proxy_contract.add_implementation(
        declared_contract_a.class_hash, NO_EIC, [1, 2, 3], NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    # The concrete impl awaits 2 elements. not three.
    with pytest.raises(StarkException, match="ILLEGAL_INIT_SIZE"):
        await proxy_contract.upgrade_to(
            declared_contract_a.class_hash, NO_EIC, [1, 2, 3], NOT_FINAL
        ).invoke(caller_address=gov)

    init_vec = [3, 4]

    # Set a first implementation on the proxy.
    await proxy_contract.add_implementation(
        declared_contract_a.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    await proxy_contract.upgrade_to(
        declared_contract_a.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    execution_info = await proxy_contract.implementation().call()
    assert execution_info.result == (declared_contract_a.class_hash,)

    # Assert contract is set as initialized.
    assert (await wrapped_impl.initialized().call()).result[0] == 1

    # deployed_contract_a initializer assigns the sum of params into stored_value.
    execution_info = await wrapped_impl.get_value().call()
    assert execution_info.result[0] == sum(init_vec)

    # Query a code indicative function, to verify it's the right implementation.
    execution_info = await wrapped_impl.get_magic_number().call()
    assert execution_info.result == (magic_number_a,)

    # Set a different implementation on the proxy.
    await proxy_contract.add_implementation(
        declared_contract_b.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    await proxy_contract.upgrade_to(
        declared_contract_b.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    execution_info = await proxy_contract.implementation().call()
    assert execution_info.result == (declared_contract_b.class_hash,)

    # deployed_contract_b initializer assigns the product sum of params into stored_value,
    # but, since contract is already initialized - it's unchanged!
    execution_info = await wrapped_impl.get_value().call()
    assert execution_info.result[0] == sum(init_vec)

    # Query a code indicative function, to verify it's the right implementation.
    execution_info = await wrapped_impl.get_magic_number().call()
    assert execution_info.result == (magic_number_b,)


@pytest.mark.asyncio
async def test_block_init(proxy_contract, wrapped_impl) -> None:
    """
    Test that one cannot call initialize() directly on the proxy, wrapped or unwrapped.
    """
    for _contract in locals().values():
        with pytest.raises(StarkException, match="DIRECT_CALL_PROHIBITED"):
            await _contract.initialize([0]).call()


@pytest.mark.asyncio
async def test_state_retention(
    starknet: Starknet,
    proxy_contract: StarknetContract,
    wrapped_impl: StarknetContract,
    deployed_contract_a: StarknetContract,
    deployed_contract_b: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_contract_b: DeclaredClass,
    gov: int,
) -> None:
    """
    Tests that the proxy hold the state, and that the implementation state is intact,
    and of no effect on the wrapped implementation state.
    Also test that changing implementation doesn't harm the state.
    """
    # Set and check a state change directly in impl contract.

    impl_a_test_value = 100000001
    impl_b_test_value = 100000002
    await deployed_contract_a.set_value(impl_a_test_value).invoke()
    await deployed_contract_b.set_value(impl_b_test_value).invoke()
    assert (await deployed_contract_a.get_value().call()).result[0] == impl_a_test_value
    assert (await deployed_contract_b.get_value().call()).result[0] == impl_b_test_value

    init_vec = [3, 4]

    # Set first implementation on the proxy.
    await proxy_contract.add_implementation(
        declared_contract_a.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    await proxy_contract.upgrade_to(
        declared_contract_a.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    assert (await proxy_contract.implementation().call()).result[
        0
    ] == declared_contract_a.class_hash

    # Check that the state on the wrapped contract set by impl_a init function.
    assert (await wrapped_impl.get_value().call()).result[0] == sum(init_vec)

    # Set and check a state change on the wrapped contract.
    test_value_1 = 200000001
    await wrapped_impl.set_value(test_value_1).invoke()
    assert (await wrapped_impl.get_value().call()).result[0] == test_value_1

    # Switch to second implementation.
    await proxy_contract.add_implementation(
        declared_contract_b.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    advance_time(starknet, default_delay)
    await proxy_contract.upgrade_to(
        declared_contract_b.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    assert (await proxy_contract.implementation().call()).result[
        0
    ] == declared_contract_b.class_hash

    # Check that the state on the wrapped contract changed by init of impl_b.
    assert (await wrapped_impl.get_value().call()).result[0] == test_value_1

    # Alter the state on then wrapped contract.
    test_value_2 = 200000002
    await wrapped_impl.set_value(test_value_2).invoke()
    assert (await wrapped_impl.get_value().call()).result[0] == test_value_2

    # Switch back to the first implementation.
    await proxy_contract.upgrade_to(
        declared_contract_a.class_hash, NO_EIC, init_vec, NOT_FINAL
    ).invoke(caller_address=gov)
    assert (await proxy_contract.implementation().call()).result[
        0
    ] == declared_contract_a.class_hash

    # Check that the state on the wrapped contract re-set by impl_a init.
    assert (await wrapped_impl.get_value().call()).result[0] == test_value_2

    # Check that state on the the implementation contract remain as expected,
    # and not as set on the wrapped contract.
    assert (await deployed_contract_a.get_value().call()).result[0] == impl_a_test_value
    assert (await deployed_contract_b.get_value().call()).result[0] == impl_b_test_value


@pytest.mark.asyncio
async def test_add_impl(starknet: Starknet, proxy_contract: StarknetContract, gov: int):
    impl = 27818281828
    init_vector = [3, 14, 159]

    # Only governor can add an implementation.
    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await proxy_contract.add_implementation(impl, NO_EIC, init_vector, NOT_FINAL).call()
    exec_info = await proxy_contract.add_implementation(
        impl, NO_EIC, init_vector, NOT_FINAL
    ).invoke(caller_address=gov)

    # Assert correct event emitted.
    impl_added_event_object = create_event_object(proxy_contract, IMPLEMENTATION_ADDED_EVENT)
    expected_event = impl_added_event_object(
        implementation_hash=impl, eic_hash=NO_EIC, init_vector=init_vector, final=NOT_FINAL
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    exec_info = await proxy_contract.implementation_time(
        impl, NO_EIC, init_vector, NOT_FINAL
    ).call()
    assert exec_info.result[0] == starknet_time(starknet) + default_delay


@pytest.mark.asyncio
async def test_remove_impl(starknet: Starknet, proxy_contract: StarknetContract, gov: int):
    impl = 1970
    init_vector = [3, 14, 15927]
    await proxy_contract.add_implementation(impl, NO_EIC, init_vector, NOT_FINAL).invoke(
        caller_address=gov
    )
    exec_info = await proxy_contract.implementation_time(
        impl, NO_EIC, init_vector, NOT_FINAL
    ).call()

    # Activation time set.
    assert exec_info.result[0] == starknet_time(starknet) + default_delay

    # Only governor can remove an implementation.
    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await proxy_contract.remove_implementation(impl, NO_EIC, init_vector, NOT_FINAL).call()
    exec_info = await proxy_contract.remove_implementation(
        impl, NO_EIC, init_vector, NOT_FINAL
    ).invoke(caller_address=gov)

    # Assert correct event emitted.
    impl_removed_event_object = create_event_object(proxy_contract, IMPLEMENTATION_REMOVED_EVENT)
    expected_event = impl_removed_event_object(
        implementation_hash=impl, eic_hash=NO_EIC, init_vector=init_vector, final=NOT_FINAL
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    exec_info = await proxy_contract.implementation_time(
        impl, NO_EIC, init_vector, NOT_FINAL
    ).call()

    # Activation time cleared.
    assert exec_info.result[0] == 0


@pytest.mark.asyncio
async def test_eic_after_regular_wrap(
    starknet: Starknet,
    wrapped_impl: StarknetContract,
    proxy_contract: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_contract_b: DeclaredClass,
    declared_eic_impl: DeclaredClass,
    gov: int,
):
    # No implementation currently set.
    assert (await proxy_contract.implementation().call()).result[0] == 0

    # Define implementation 1.
    impl1 = declared_contract_a.class_hash
    init_vector1 = [5, 6]

    # Define implementation 2.
    impl2 = declared_contract_b.class_hash

    # Add implementation 1 & 2.
    await proxy_contract.add_implementation(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )

    assert (await proxy_contract.implementation().call()).result[0] == impl1
    post_impl1_value = (await wrapped_impl.get_value().call()).result[0]
    assert (await wrapped_impl.initialized().call()).result[0] == True

    eic_hash = declared_eic_impl.class_hash
    eic_init_vector = [200]  # The test_eic increments the store_value by the passed value.
    await proxy_contract.add_implementation(impl2, eic_hash, eic_init_vector, NOT_FINAL).invoke(
        caller_address=gov
    )

    # EIC upgrade complies with time-lock as well.
    with pytest.raises(StarkException, match="NOT_ENABLED_YET"):
        await proxy_contract.upgrade_to(impl2, eic_hash, eic_init_vector, NOT_FINAL).call(
            caller_address=gov
        )
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)
    await proxy_contract.upgrade_to(impl2, eic_hash, eic_init_vector, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Upgrade succeeded (switched to impl2).
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl2
    post_impl2_value = (await wrapped_impl.get_value().call()).result[0]

    # EIC init run as expected.
    assert post_impl2_value == post_impl1_value + eic_init_vector[0]


@pytest.mark.asyncio
async def test_init_via_eic(
    starknet: Starknet,
    wrapped_impl: StarknetContract,
    proxy_contract: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_eic_impl: DeclaredClass,
    gov: int,
):
    # No implementation currently set.
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == 0

    impl1 = declared_contract_a.class_hash

    eic_init_vector = [200]  # Test_eic increments the store_value by the passed value.
    eic_hash = declared_eic_impl.class_hash

    impl_added_event_object = create_event_object(proxy_contract, IMPLEMENTATION_ADDED_EVENT)
    expected_event = impl_added_event_object(
        implementation_hash=impl1, eic_hash=eic_hash, init_vector=eic_init_vector, final=NOT_FINAL
    )

    # Set the first implementation via EIC.
    exec_info = await proxy_contract.add_implementation(
        impl1, eic_hash, eic_init_vector, NOT_FINAL
    ).invoke(caller_address=gov)
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    impl_upgraded_event_object = create_event_object(proxy_contract, IMPLEMENTATION_UPGRADED_EVENT)
    expected_event = impl_upgraded_event_object(
        implementation_hash=impl1, eic_hash=eic_hash, init_vector=eic_init_vector
    )
    exec_info = await proxy_contract.upgrade_to(impl1, eic_hash, eic_init_vector, NOT_FINAL).invoke(
        caller_address=gov
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    # Verify impl_1 installed properly.
    assert (await proxy_contract.implementation().call()).result[0] == impl1

    # Value is per eic logic (0 += 200) and not according to impl_a initialization.
    assert (await wrapped_impl.get_value().call()).result[0] == eic_init_vector[0]
    assert (await wrapped_impl.initialized().call()).result[0] == True

    # Re-do upgrade_to. This will re-apply eic logic i.e. += 200.
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)
    exec_info = await proxy_contract.upgrade_to(impl1, eic_hash, eic_init_vector, NOT_FINAL).invoke(
        caller_address=gov
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    assert (await wrapped_impl.get_value().call()).result[0] == 2 * eic_init_vector[0]


@pytest.mark.asyncio
async def test_eic_finalize(
    starknet: Starknet,
    wrapped_impl: StarknetContract,
    proxy_contract: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_contract_b: DeclaredClass,
    declared_eic_impl: DeclaredClass,
    gov: int,
):
    """
    1. EIC upgrade can finalize.
    2. EIC upgrade (too) can not be performed when finalized.
    """
    # No implementation currently set.
    assert (await proxy_contract.implementation().call()).result[0] == 0

    impl1 = declared_contract_a.class_hash
    impl2 = declared_contract_b.class_hash
    eic_hash = declared_eic_impl.class_hash
    eic_init_vector = [200]

    await proxy_contract.add_implementation(impl1, eic_hash, [0], NOT_FINAL).invoke(
        caller_address=gov
    )
    await proxy_contract.upgrade_to(impl1, eic_hash, [0], NOT_FINAL).invoke(caller_address=gov)

    assert (await wrapped_impl.get_value().call()).result[0] == 0
    assert (await proxy_contract.implementation().call()).result[0] == impl1
    assert (await wrapped_impl.initialized().call()).result[0] == True

    # Change impl using eic. This time finalizing.
    await proxy_contract.add_implementation(impl2, eic_hash, eic_init_vector, FINAL).invoke(
        caller_address=gov
    )
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)
    await proxy_contract.upgrade_to(impl2, eic_hash, eic_init_vector, FINAL).invoke(
        caller_address=gov
    )

    # EIC Init took place.
    assert (await wrapped_impl.get_value().call()).result[0] == eic_init_vector[0]
    # Impl replaced.
    assert (await proxy_contract.implementation().call()).result[0] == impl2
    # Finalized flag set.
    assert (await proxy_contract.finalized().call()).result[0] == True

    # EIC Path is blocked as well when finalized.
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)
    with pytest.raises(StarkException, match="FINALIZED"):
        await proxy_contract.upgrade_to(impl2, eic_hash, eic_init_vector, FINAL).invoke(
            caller_address=gov
        )


@pytest.mark.asyncio
async def test_upgrade_to(
    starknet: Starknet,
    proxy_contract: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_contract_b: DeclaredClass,
    gov: int,
):
    # No implementation currently set.
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == 0

    # Define implementation 1.
    impl1 = declared_contract_a.class_hash
    init_vector1 = [5, 6]

    # Define implementation 2.
    impl2 = declared_contract_b.class_hash
    init_vector2 = [6, 10]

    # Add implementation 1 & 2.
    await proxy_contract.add_implementation(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    await proxy_contract.add_implementation(impl2, NO_EIC, init_vector2, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Only governor can execute upgrade_to.
    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).call()

    # Switch to initial impl (impl1) and assert its address.
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl1

    # Not enough time passed since adding implementation.
    with pytest.raises(StarkException, match="NOT_ENABLED_YET"):
        await proxy_contract.upgrade_to(impl2, NO_EIC, init_vector2, NOT_FINAL).call(
            caller_address=gov
        )

    # Advance the starknet blockinfo timestamp manually.
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)

    # Switch to impl2 and assert impl address.
    exec_info = await proxy_contract.upgrade_to(impl2, NO_EIC, init_vector2, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Assert correct event emitted.
    impl_upgraded_event_object = create_event_object(proxy_contract, IMPLEMENTATION_UPGRADED_EVENT)
    expected_event = impl_upgraded_event_object(
        implementation_hash=impl2, eic_hash=NO_EIC, init_vector=init_vector2
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl2

    # Revert immediately to impl1.
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl1

    # Remove impl2 from the proxy.
    await proxy_contract.remove_implementation(impl2, NO_EIC, init_vector2, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Fail to switch to impl2, as it was removed.
    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl2, NO_EIC, init_vector2, NOT_FINAL).call(
            caller_address=gov
        )

    # Implementation is still impl1.
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl1


@pytest.mark.asyncio
async def test_impl_revert(
    starknet: Starknet,
    proxy_contract: StarknetContract,
    wrapped_impl: StarknetContract,
    declared_contract_a: DeclaredClass,
    declared_contract_b: DeclaredClass,
    gov: int,
) -> None:
    # No implementation currently set.
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == 0

    # Define implementation 1 (impl_b this time).
    impl1 = declared_contract_b.class_hash
    init_vector1 = [5, 6]

    # Define implementation 2 (impl_a). No need for init_vector2.
    impl2 = declared_contract_a.class_hash

    # Load implementations.
    await proxy_contract.add_implementation(impl1, NO_EIC, [], NOT_FINAL).invoke(caller_address=gov)
    await proxy_contract.add_implementation(impl2, NO_EIC, [], NOT_FINAL).invoke(caller_address=gov)
    await proxy_contract.add_implementation(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Empty init vector cannot initialize the implementation, thus cannot be used for first upgrade.
    with pytest.raises(StarkException, match="ILLEGAL_INIT_SIZE"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, [], NOT_FINAL).call(caller_address=gov)

    # Switch to initial impl (impl1) and assert its address.
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl1

    # deployed_contract_b initialize set the stored_value to param product (here: 5,6 := 30).
    assert (await wrapped_impl.get_value().call()).result[0] == 30

    # Set stored_value to a test value.
    test_value = 100000001
    await wrapped_impl.set_value(test_value).invoke()
    assert (await wrapped_impl.get_value().call()).result[0] == test_value

    # Advance the starknet blockinfo, to allow switches.
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)

    # Switch to between known impl immediately.
    implementations = [(impl1, init_vector1), (impl2, []), (impl1, [])]
    for i in range(1, 5):
        impl, init_vec = implementations[i % len(implementations)]
        await proxy_contract.upgrade_to(impl, NO_EIC, init_vec, NOT_FINAL).invoke(
            caller_address=gov
        )
        assert (await wrapped_impl.get_value().call()).result[0] == test_value
        assert (await proxy_contract.implementation().call()).result[0] == impl

    # Ensure we can't cross known impl address with unknown init vector.
    init_vector_bad = [2, 5, 7]
    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector_bad, NOT_FINAL).call(
            caller_address=gov
        )


@pytest.mark.asyncio
async def test_upgrade_finalization(
    starknet: Starknet,
    proxy_contract: StarknetContract,
    declared_contract_a: StarknetContract,
    gov: int,
) -> None:
    # No implementation currently set.
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == 0

    # Define implementation 1.
    impl1 = declared_contract_a.class_hash
    init_vector1 = [5, 6]

    # Add_implementation with the first implementations.
    await proxy_contract.add_implementation(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Check @view function to reflect expected finalization state.
    assert (await proxy_contract.finalized().call()).result[0] == False

    # Final flag part of the implementation_time key.
    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, FINAL).invoke(
            caller_address=gov
        )

    # Successfully upgrade_to the first implementations.
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )
    current_impl = (await proxy_contract.implementation().call()).result[0]
    assert current_impl == impl1

    # Check @view function to reflect expected finalization state.
    assert (await proxy_contract.finalized().call()).result[0] == False

    # Add additional implementations.
    await proxy_contract.add_implementation(impl1, NO_EIC, [], NOT_FINAL).invoke(caller_address=gov)
    await proxy_contract.add_implementation(impl1, NO_EIC, [], FINAL).invoke(caller_address=gov)
    advance_time(starknet=starknet, block_time_diff=default_delay, block_num_diff=1)

    # Switch to another non-final impl. Assert that upgraded event emitted, but finalized is not.
    # Since finalized_impl event is emitted after the upgraded_impl (as shown a few lines later)
    # the fact that event[-1] is the upgraded implies that no finalized event was emitted.
    upgraded_event_object = create_event_object(proxy_contract, IMPLEMENTATION_UPGRADED_EVENT)
    finalized_event_object = create_event_object(proxy_contract, IMPLEMENTATION_FINALIZED_EVENT)
    expected_event = upgraded_event_object(
        implementation_hash=impl1, eic_hash=NO_EIC, init_vector=[]
    )
    exec_info = await proxy_contract.upgrade_to(impl1, NO_EIC, [], NOT_FINAL).invoke(
        caller_address=gov
    )
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    # Switch to a final impl. Assert that both upgraded and finalized events are emitted.
    exec_info = await proxy_contract.upgrade_to(impl1, NO_EIC, [], FINAL).invoke(caller_address=gov)

    expected_upgrade_event = upgraded_event_object(
        implementation_hash=impl1, eic_hash=NO_EIC, init_vector=[]
    )
    expected_finalize_event = finalized_event_object(implementation_hash=impl1)
    assert_events_equal(expected_upgrade_event, exec_info.main_call_events[-2])
    assert_events_equal(expected_finalize_event, exec_info.main_call_events[-1])

    # Check @view function to reflect expected finalization state.
    assert (await proxy_contract.finalized().call()).result[0] == True

    # Now we cannot switch/revert to any impl.
    with pytest.raises(StarkException, match="FINALIZED"):
        exec_info = await proxy_contract.upgrade_to(impl1, NO_EIC, [], NOT_FINAL).call(
            caller_address=gov
        )

    # Not even the one we last switched to.
    with pytest.raises(StarkException, match="FINALIZED"):
        exec_info = await proxy_contract.upgrade_to(impl1, NO_EIC, [], FINAL).call(
            caller_address=gov
        )


@pytest.mark.asyncio
async def test_key_add_impl(
    proxy_contract: StarknetContract,
    declared_contract_a: DeclaredClass,
    gov: int,
):
    impl1 = declared_contract_a.class_hash
    init_vector1 = [5, 6]

    # Add implementation 1.
    await proxy_contract.add_implementation(impl1, NO_EIC, init_vector1, NOT_FINAL).invoke(
        caller_address=gov
    )

    # Try and fail. various combinations, each with a diff in another field.
    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1 + 1, NO_EIC, init_vector1, NOT_FINAL).call(
            caller_address=gov
        )

    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1, NO_EIC + 1, init_vector1, NOT_FINAL).call(
            caller_address=gov
        )

    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1 + [1], NOT_FINAL).call(
            caller_address=gov
        )

    with pytest.raises(StarkException, match="UNKNOWN_IMPLEMENTATION"):
        await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL + 1).call(
            caller_address=gov
        )

    # And the correct one does not throw.
    await proxy_contract.upgrade_to(impl1, NO_EIC, init_vector1, NOT_FINAL).call(caller_address=gov)
