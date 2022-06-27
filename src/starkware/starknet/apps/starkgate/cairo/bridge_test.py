import asyncio
import copy
import random

import pytest

from starkware.starknet.apps.starkgate.cairo.contracts import bridge_contract_class
from starkware.starknet.apps.starkgate.conftest import str_to_felt
from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.solidity.starknet_test_utils import Uint256
from starkware.starknet.std_contracts.ERC20.contracts import erc20_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.contracts import proxy_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.test_utils import advance_time
from starkware.starknet.testing.contract import DeclaredClass, StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

ETH_ADDRESS_BOUND = 2**160
GOVERNOR_ADDRESS = str_to_felt("GOVERNOR")
L1_BRIDGE_ADDRESS = 42
L1_ACCOUNT = 1
L1_BRIDGE_SET_EVENT_IDENTIFIER = "l1_bridge_set"
L2_TOKEN_SET_EVENT_IDENTIFIER = "l2_token_set"
WITHDRAW_INITIATED_EVENT_IDENTIFIER = "withdraw_initiated"
DEPOSIT_HANDLED_EVENT_IDENTIFIER = "deposit_handled"
BRIDGE_CONTRACT_IDENTITY = "STARKGATE"
BRIDGE_CONTRACT_VERSION = 1


initial_balances = {1: 13, 2: 10}
uninitialized_account = 3
initial_total_supply = sum(initial_balances.values())
initialized_account = random.choice(list(initial_balances.keys()))

# 0 < BURN_AMOUNT < MINT_AMOUNT.
MINT_AMOUNT = 15
BURN_AMOUNT = MINT_AMOUNT - 1
UPGRADE_DELAY = 0


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    starknet = await Starknet.empty()
    # We want to start with a non-zero block/time (this would fail tests).
    advance_time(starknet=starknet, block_time_diff=1, block_num_diff=1)
    return starknet


@pytest.fixture(scope="session")
async def session_proxy_contract(session_starknet: Starknet) -> StarknetContract:
    proxy = await session_starknet.deploy(
        constructor_calldata=[UPGRADE_DELAY], contract_class=proxy_contract_class
    )
    await proxy.init_governance().invoke(caller_address=GOVERNOR_ADDRESS)
    return proxy


@pytest.fixture(scope="session")
async def declared_bridge_impl(session_starknet: Starknet) -> DeclaredClass:
    return await session_starknet.declare(contract_class=bridge_contract_class)


@pytest.fixture(scope="session")
async def session_token_contract(
    session_starknet: Starknet,
    token_name: int,
    token_symbol: int,
    token_decimals: int,
    session_proxy_contract: StarknetContract,
) -> StarknetContract:
    token_proxy = await session_starknet.deploy(
        constructor_calldata=[UPGRADE_DELAY], contract_class=proxy_contract_class
    )
    await token_proxy.init_governance().invoke(caller_address=GOVERNOR_ADDRESS)
    l2_bridge_address = session_proxy_contract.contract_address
    declared_token_impl = await session_starknet.declare(contract_class=erc20_contract_class)
    NOT_FINAL = False
    NO_EIC = 0
    proxy_func_params = [
        declared_token_impl.class_hash,
        NO_EIC,
        [
            token_name,
            token_symbol,
            token_decimals,
            l2_bridge_address,
        ],
        NOT_FINAL,
    ]
    # Set a first implementation on the proxy.
    await token_proxy.add_implementation(*proxy_func_params).invoke(caller_address=GOVERNOR_ADDRESS)
    await token_proxy.upgrade_to(*proxy_func_params).invoke(caller_address=GOVERNOR_ADDRESS)
    wrapped_token = token_proxy.replace_abi(impl_contract_abi=declared_token_impl.abi)

    # Initial balance setup.
    for account in initial_balances:
        await wrapped_token.permissionedMint(
            recipient=account, amount=Uint256(initial_balances[account]).uint256()
        ).invoke(caller_address=l2_bridge_address)
    return wrapped_token


@pytest.fixture
async def starknet(
    session_starknet: Starknet, session_bridge_contract: StarknetContract
) -> Starknet:
    # Order enforcement. This way we enforce state clone only post proxy wiring.
    assert session_bridge_contract
    return copy.deepcopy(session_starknet)


@pytest.fixture(scope="session")
async def session_bridge_contract(
    session_starknet: Starknet,
    session_proxy_contract: StarknetContract,
    declared_bridge_impl: DeclaredClass,
    session_token_contract: StarknetContract,
) -> StarknetContract:
    NOT_FINAL = False
    NO_EIC = 0
    proxy_func_params = [
        declared_bridge_impl.class_hash,
        NO_EIC,
        [GOVERNOR_ADDRESS],
        NOT_FINAL,
    ]
    # Set a first implementation on the proxy.
    await session_proxy_contract.add_implementation(*proxy_func_params).invoke(
        caller_address=GOVERNOR_ADDRESS
    )
    await session_proxy_contract.upgrade_to(*proxy_func_params).invoke(
        caller_address=GOVERNOR_ADDRESS
    )
    wrapped_bridge = session_proxy_contract.replace_abi(impl_contract_abi=declared_bridge_impl.abi)

    # Set L1 bridge address on the bridge.
    await wrapped_bridge.set_l1_bridge(l1_bridge_address=L1_BRIDGE_ADDRESS).invoke(
        caller_address=GOVERNOR_ADDRESS
    )
    assert (await wrapped_bridge.get_l1_bridge().call()).result[0] == L1_BRIDGE_ADDRESS

    # Verify emission of respective event.
    expected_event = Event(
        from_address=wrapped_bridge.contract_address,
        keys=[get_selector_from_name(L1_BRIDGE_SET_EVENT_IDENTIFIER)],
        data=[L1_BRIDGE_ADDRESS],
    )
    assert expected_event == session_starknet.state.events[-1]

    # Set L2 token address on the bridge.
    l2_token_address = session_token_contract.contract_address
    await wrapped_bridge.set_l2_token(l2_token_address=l2_token_address).invoke(
        caller_address=GOVERNOR_ADDRESS
    )

    # Verify emission of respective event.
    expected_event = Event(
        from_address=wrapped_bridge.contract_address,
        keys=[get_selector_from_name(L2_TOKEN_SET_EVENT_IDENTIFIER)],
        data=[l2_token_address],
    )
    assert expected_event == session_starknet.state.events[-1]
    assert (await wrapped_bridge.get_l2_token().call()).result[0] == l2_token_address
    return wrapped_bridge


@pytest.fixture
async def bridge_contract(
    starknet: Starknet,
    session_bridge_contract: StarknetContract,
) -> StarknetContract:
    assert bridge_contract_class.abi is not None, "Missing ABI."
    return StarknetContract(
        state=starknet.state,
        abi=session_bridge_contract.abi,
        contract_address=session_bridge_contract.contract_address,
        deploy_execution_info=session_bridge_contract.deploy_execution_info,
    )


@pytest.fixture
async def token_contract(
    starknet: Starknet, session_token_contract: StarknetContract
) -> StarknetContract:
    return StarknetContract(
        state=starknet.state,
        abi=session_token_contract.abi,
        contract_address=session_token_contract.contract_address,
        deploy_execution_info=session_token_contract.deploy_execution_info,
    )


@pytest.mark.asyncio
async def test_bridge_wrapped_properly(
    declared_bridge_impl: StarknetContract,
    session_bridge_contract: StarknetContract,
    bridge_contract: StarknetContract,
    session_proxy_contract: StarknetContract,
):
    bridge_class_hash = (await session_proxy_contract.implementation().call()).result[0]
    assert declared_bridge_impl.class_hash == bridge_class_hash
    assert session_bridge_contract.contract_address == bridge_contract.contract_address
    assert session_bridge_contract.state is not bridge_contract.state
    assert session_bridge_contract.contract_address == session_proxy_contract.contract_address
    assert (await bridge_contract.initialized().call()).result[0] == True


@pytest.mark.asyncio
async def test_get_governor(bridge_contract: StarknetContract):
    execution_info = await bridge_contract.get_governor().call()
    assert execution_info.result[0] == GOVERNOR_ADDRESS


@pytest.mark.asyncio
async def test_get_l1_bridge(bridge_contract: StarknetContract):
    execution_info = await bridge_contract.get_l1_bridge().call()
    assert execution_info.result[0] == L1_BRIDGE_ADDRESS


@pytest.mark.asyncio
async def test_get_l2_token(bridge_contract: StarknetContract, token_contract: StarknetContract):
    execution_info = await bridge_contract.get_l2_token().call()
    assert execution_info.result[0] == token_contract.contract_address


@pytest.mark.asyncio
async def test_get_identity(bridge_contract: StarknetContract):
    execution_info = await bridge_contract.get_identity().call()
    assert execution_info.result[0] == str_to_felt(BRIDGE_CONTRACT_IDENTITY)


@pytest.mark.asyncio
async def test_get_version(bridge_contract: StarknetContract):
    execution_info = await bridge_contract.get_version().call()
    assert execution_info.result[0] == BRIDGE_CONTRACT_VERSION


@pytest.mark.asyncio
async def test_handle_deposit_wrong_l1_address(
    starknet: Starknet,
    bridge_contract: StarknetContract,
):
    with pytest.raises(StarkException, match=r"assert from_address = expected_from_address"):
        await starknet.send_message_to_l2(
            from_address=L1_BRIDGE_ADDRESS + 1,
            to_address=bridge_contract.contract_address,
            selector=get_selector_from_name("handle_deposit"),
            payload=[initialized_account, Uint256(MINT_AMOUNT).low, Uint256(MINT_AMOUNT).high],
        )


@pytest.mark.asyncio
async def test_handle_deposit_zero_account(
    starknet: Starknet,
    bridge_contract: StarknetContract,
):
    with pytest.raises(StarkException, match=r"assert_not_zero\(recipient\)"):
        await starknet.send_message_to_l2(
            from_address=L1_BRIDGE_ADDRESS,
            to_address=bridge_contract.contract_address,
            selector=get_selector_from_name("handle_deposit"),
            payload=[0, Uint256(MINT_AMOUNT).low, Uint256(MINT_AMOUNT).high],
        )


@pytest.mark.asyncio
async def test_handle_deposit_total_supply_out_of_range(
    starknet: Starknet,
    bridge_contract: StarknetContract,
):
    amount = Uint256(2**256 - initial_total_supply)
    with pytest.raises(StarkException, match=r"assert \(is_overflow\) = 0"):
        await starknet.send_message_to_l2(
            from_address=L1_BRIDGE_ADDRESS,
            to_address=bridge_contract.contract_address,
            selector=get_selector_from_name("handle_deposit"),
            payload=[uninitialized_account, amount.low, amount.high],
        )


@pytest.mark.asyncio
async def test_handle_deposit_happy_flow(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
):
    payload = [uninitialized_account, Uint256(MINT_AMOUNT).low, Uint256(MINT_AMOUNT).high]
    await starknet.send_message_to_l2(
        from_address=L1_BRIDGE_ADDRESS,
        to_address=bridge_contract.contract_address,
        selector=get_selector_from_name("handle_deposit"),
        payload=payload,
    )

    # Verify the respective event is emitted.
    expected_event = Event(
        from_address=bridge_contract.contract_address,
        keys=[get_selector_from_name(DEPOSIT_HANDLED_EVENT_IDENTIFIER)],
        data=payload,
    )
    # The deposit_handled event should be the last event emitted.
    assert expected_event == starknet.state.events[-1]

    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result[0] == Uint256(MINT_AMOUNT).uint256()
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == Uint256(initial_total_supply + MINT_AMOUNT).uint256()


@pytest.mark.asyncio
async def test_initiate_withdraw_invalid_l1_recipient(
    bridge_contract: StarknetContract,
):
    with pytest.raises(StarkException, match=r"assert_lt_felt\(l1_recipient, ETH_ADDRESS_BOUND\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=ETH_ADDRESS_BOUND,
            amount=Uint256(initial_balances[initialized_account]).uint256(),
        ).call(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_initiate_withdraw_zero_account(bridge_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(account\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=L1_ACCOUNT, amount=Uint256(BURN_AMOUNT).uint256()
        ).call(caller_address=0)


@pytest.mark.asyncio
async def test_initiate_withdraw_amount_bigger_than_balance(bridge_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_balance\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=L1_ACCOUNT,
            amount=Uint256(initial_balances[initialized_account] + 1).uint256(),
        ).call(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_initiate_withdraw_happy_flow(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
):
    await starknet.send_message_to_l2(
        from_address=L1_BRIDGE_ADDRESS,
        to_address=bridge_contract.contract_address,
        selector=get_selector_from_name("handle_deposit"),
        payload=[initialized_account, Uint256(MINT_AMOUNT).low, Uint256(MINT_AMOUNT).high],
    )

    execution_info = await bridge_contract.initiate_withdraw(
        l1_recipient=L1_ACCOUNT, amount=Uint256(BURN_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)

    # Verify the respective event is emitted.
    expected_event = Event(
        from_address=bridge_contract.contract_address,
        keys=[get_selector_from_name(WITHDRAW_INITIATED_EVENT_IDENTIFIER)],
        data=[L1_ACCOUNT, Uint256(BURN_AMOUNT).low, Uint256(BURN_AMOUNT).high, initialized_account],
    )
    # The withdraw_initiated event should be the last event emitted.
    assert expected_event == starknet.state.events[-1]

    expected_balance = Uint256(
        initial_balances[initialized_account] + MINT_AMOUNT - BURN_AMOUNT
    ).uint256()
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == expected_balance
    expected_supply = Uint256(initial_total_supply + MINT_AMOUNT - BURN_AMOUNT).uint256()
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == expected_supply
