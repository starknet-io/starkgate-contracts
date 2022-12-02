import asyncio
import copy

import pytest

from starkware.starknet.std_contracts.upgradability_proxy.contracts import governance_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.test_utils import (
    assert_events_equal,
    create_event_object,
)
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

GOVERNOR_NOMINATED_EVENT = "governor_nominated"
NOMINATION_CANCELLED_EVENT = "nomination_cancelled"
GOVERNOR_REMOVED_EVENT = "governor_removed"
GOVERNANCE_ACCEPTED_EVENT = "governance_accepted"


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    return await Starknet.empty()


@pytest.fixture(scope="session")
async def session_gov_contract(session_starknet: Starknet) -> StarknetContract:
    return await session_starknet.deploy(
        constructor_calldata=[], contract_class=governance_contract_class
    )


@pytest.fixture
async def starknet(session_starknet: Starknet) -> Starknet:
    return copy.deepcopy(session_starknet)


@pytest.fixture
async def governance_contract(
    starknet: Starknet, session_gov_contract: StarknetContract
) -> StarknetContract:
    assert governance_contract_class.abi is not None
    return StarknetContract(
        state=starknet.state,
        abi=governance_contract_class.abi,
        contract_address=session_gov_contract.contract_address,
        deploy_execution_info=session_gov_contract.deploy_execution_info,
    )


@pytest.mark.asyncio
async def test_governance_init(governance_contract: StarknetContract):
    GOV = 42
    execution_info = await governance_contract.is_governor(GOV).call()
    assert execution_info.result == (0,)

    execution_info = await governance_contract.init_governance().invoke(caller_address=GOV)
    nominated_event_object = create_event_object(governance_contract, GOVERNOR_NOMINATED_EVENT)
    expected_nomination_event = nominated_event_object(new_governor_nominee=GOV, nominated_by=GOV)

    accepted_event_object = create_event_object(governance_contract, GOVERNANCE_ACCEPTED_EVENT)
    expected_accepted_event = accepted_event_object(new_governor=GOV)

    # Init governance emits two events, nomination then acceptance.
    assert_events_equal(expected_nomination_event, execution_info.main_call_events[-2])
    assert_events_equal(expected_accepted_event, execution_info.main_call_events[-1])

    execution_info = await governance_contract.is_governor(GOV).call()
    assert execution_info.result == (1,)

    with pytest.raises(StarkException, match="ALREADY_INITIALIZED"):
        await governance_contract.init_governance().call(caller_address=GOV)


@pytest.mark.asyncio
async def test_multi_nominate_accept(governance_contract: StarknetContract):
    INIT_GOV = 42

    # Only governor can nominate.
    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await governance_contract.nominate_new_governor(142).call(caller_address=INIT_GOV)
    await governance_contract.init_governance().invoke(caller_address=INIT_GOV)

    nominees = list(range(43, 47))
    for nom in nominees:
        execution_info = await governance_contract.is_governor(nom).call()
        assert execution_info.result == (0,)

    # Nominate in reversed order (we will accept in straight order).
    nominated_event_object = create_event_object(governance_contract, GOVERNOR_NOMINATED_EVENT)
    for nom in reversed(nominees):
        expected_event = nominated_event_object(new_governor_nominee=nom, nominated_by=INIT_GOV)
        exec_info = await governance_contract.nominate_new_governor(nom).invoke(
            caller_address=INIT_GOV
        )

        # Proper event emitted on nomination.
        assert_events_equal(expected_event, exec_info.main_call_events[-1])

    accepted_event_object = create_event_object(governance_contract, GOVERNANCE_ACCEPTED_EVENT)
    for nom in nominees:
        exec_info = await governance_contract.accept_governance().invoke(caller_address=nom)

        # Proper event emitted on acceptance.
        assert_events_equal(accepted_event_object(new_governor=nom), exec_info.main_call_events[-1])

    for nom in nominees:
        exec_info = await governance_contract.is_governor(nom).call()
        assert exec_info.result == (1,)


@pytest.mark.asyncio
async def test_cancel_nomination(governance_contract: StarknetContract):
    INIT_GOV = 42
    nominee_1 = 43
    nominee_2 = 44

    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await governance_contract.cancel_nomination(nominee_1).call(caller_address=INIT_GOV)
    await governance_contract.init_governance().invoke(caller_address=INIT_GOV)

    # Cancel nomination succeeds quietly even if not nominee not nominated before.
    ex_info = await governance_contract.cancel_nomination(nominee_1).invoke(caller_address=INIT_GOV)

    # No events emitted on void cancellation.
    assert [] == ex_info.main_call_events

    # Nominate nominees 1 & 2.
    await governance_contract.nominate_new_governor(nominee_1).invoke(caller_address=INIT_GOV)
    await governance_contract.nominate_new_governor(nominee_2).invoke(caller_address=INIT_GOV)

    # Cancel nominee 1.
    cancel_event_object = create_event_object(governance_contract, NOMINATION_CANCELLED_EVENT)
    expected_event = cancel_event_object(cancelled_nominee=nominee_1, cancelled_by=INIT_GOV)
    ex_info = await governance_contract.cancel_nomination(nominee_1).invoke(caller_address=INIT_GOV)

    # Proper event emitted on cancellation.
    assert_events_equal(expected_event, ex_info.main_call_events[-1])

    # Nominee 2 can accept.
    await governance_contract.accept_governance().invoke(caller_address=nominee_2)
    ex_info = await governance_contract.is_governor(nominee_2).call()
    assert ex_info.result == (1,)

    # Nominee 1 cannot accept.
    with pytest.raises(StarkException, match="NOT_A_GOVERNANCE_CANDIDATE"):
        await governance_contract.accept_governance().call(caller_address=nominee_1)
    ex_info = await governance_contract.is_governor(nominee_1).call()
    assert ex_info.result == (0,)


@pytest.mark.asyncio
async def test_accept_nomination(governance_contract: StarknetContract):
    INIT_GOV = 42
    nominee = 43

    await governance_contract.init_governance().invoke(caller_address=INIT_GOV)

    # Cannot accept before nomination.
    with pytest.raises(StarkException, match="NOT_A_GOVERNANCE_CANDIDATE"):
        await governance_contract.accept_governance().call(caller_address=nominee)

    # Nominate nominees.
    await governance_contract.nominate_new_governor(nominee).invoke(caller_address=INIT_GOV)

    # Accept nomination successfully.
    await governance_contract.accept_governance().invoke(caller_address=nominee)
    execution_info = await governance_contract.is_governor(nominee).call()
    assert execution_info.result == (1,)

    # Nominee cleared from candidancy once accepted.
    with pytest.raises(StarkException, match="NOT_A_GOVERNANCE_CANDIDATE"):
        await governance_contract.accept_governance().call(caller_address=nominee)

    # Cannot nominate active governors.
    with pytest.raises(StarkException, match="ALREADY_GOVERNOR"):
        await governance_contract.nominate_new_governor(nominee).call(caller_address=INIT_GOV)


@pytest.mark.asyncio
async def test_remove_governor(governance_contract: StarknetContract):
    INIT_GOV = 42
    nominee = 43

    await governance_contract.init_governance().invoke(caller_address=INIT_GOV)
    exec_info = await governance_contract.is_governor(INIT_GOV).call()
    assert exec_info.result == (1,)

    # Only a governor can remove a governor.
    with pytest.raises(StarkException, match="ONLY_GOVERNOR"):
        await governance_contract.remove_governor(INIT_GOV).call(caller_address=nominee)

    # Governor cannot remove oneself.
    with pytest.raises(StarkException, match="SELF_REMOVE"):
        await governance_contract.remove_governor(INIT_GOV).call(caller_address=INIT_GOV)

    # Nominate nominees & Accept governance.
    await governance_contract.nominate_new_governor(nominee).invoke(caller_address=INIT_GOV)
    await governance_contract.accept_governance().invoke(caller_address=nominee)

    removed_event_object = create_event_object(governance_contract, GOVERNOR_REMOVED_EVENT)
    expected_event = removed_event_object(removed_governor=INIT_GOV, removed_by=nominee)
    exec_info = await governance_contract.remove_governor(INIT_GOV).invoke(caller_address=nominee)

    # Proper event emitted on removal.
    assert_events_equal(expected_event, exec_info.main_call_events[-1])

    exec_info = await governance_contract.is_governor(INIT_GOV).call()
    assert exec_info.result == (0,)


@pytest.mark.asyncio
async def test_zero_governor_address(governance_contract: StarknetContract):
    """
    Test that ZERO_ADDRESS cannot be made governor by init, or by nomination.
    """
    ZERO_GOV = 0
    GD_GOV = 4006

    with pytest.raises(StarkException, match="ZERO_ADDRESS"):
        await governance_contract.init_governance().invoke(caller_address=ZERO_GOV)

    await governance_contract.init_governance().invoke(caller_address=GD_GOV)
    with pytest.raises(StarkException, match="ZERO_ADDRESS"):
        await governance_contract.nominate_new_governor(ZERO_GOV).invoke(caller_address=GD_GOV)
