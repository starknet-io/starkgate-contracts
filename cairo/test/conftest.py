import asyncio
import copy
import os

import pytest

from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.testing.contract import DeclaredClass, StarknetContract
from starkware.starknet.testing.starknet import Starknet

from test.utils import advance_time, str_to_felt, Uint256

FILE_DIR = os.path.dirname(__file__)
CAIRO_PATH = [os.path.join(FILE_DIR, "../../cairo/contracts")]
BRIDGE_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/token_bridge.cairo")
ERC20_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/starknet/std_contracts/ERC20/ERC20.cairo")
GOVERNANCE_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/starknet/std_contracts/upgradability_proxy/governance.cairo")
PROXY_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/starknet/std_contracts/upgradability_proxy/proxy.cairo")


CONTRACT_A_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/test_contracts/impl_contract_a.cairo")
CONTRACT_B_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/test_contracts/impl_contract_b.cairo")
CONTRACT_EIC_FILE = os.path.join(FILE_DIR, "../../cairo/contracts/test_contracts/test_eic.cairo")


L1_BRIDGE_ADDRESS = 42
L1_ACCOUNT = 1
L1_BRIDGE_SET_EVENT_IDENTIFIER = "l1_bridge_set"
L2_TOKEN_SET_EVENT_IDENTIFIER = "l2_token_set"
GOVERNOR_ADDRESS = str_to_felt("GOVERNOR")
UPGRADE_DELAY = 0

initial_balances = {1: 13, 2: 10}


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()

@pytest.fixture(scope="session")
def token_decimals() -> int:
    return 6


@pytest.fixture(scope="session")
def token_symbol() -> int:
    return str_to_felt("TKN")


@pytest.fixture(scope="session")
def token_name() -> int:
    return str_to_felt("TOKEN")


@pytest.fixture(scope="module")
async def session_starknet() -> Starknet:
    starknet = await Starknet.empty()
    # We want to start with a non-zero block/time (this would fail tests).
    advance_time(starknet=starknet, block_time_diff=1, block_num_diff=1)
    return starknet


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    starknet = await Starknet.empty()
    # We want to start with a non-zero block/time (this would fail tests).
    advance_time(starknet=starknet, block_time_diff=1, block_num_diff=1)
    return starknet

@pytest.fixture(scope="module")
async def session_proxy_contract(session_starknet: Starknet) -> StarknetContract:
    proxy = await session_starknet.deploy(
        PROXY_FILE,
        cairo_path=CAIRO_PATH,
        constructor_calldata=[UPGRADE_DELAY],
    )
    await proxy.init_governance().execute(caller_address=GOVERNOR_ADDRESS)
    return proxy

@pytest.fixture(scope="module")
async def declared_bridge_impl(session_starknet: Starknet) -> DeclaredClass:
    return await session_starknet.declare(
        BRIDGE_FILE,
        cairo_path=CAIRO_PATH,
    )

@pytest.fixture(scope="module")
async def session_token_contract(
    session_starknet: Starknet,
    token_name: int,
    token_symbol: int,
    token_decimals: int,
    session_proxy_contract: StarknetContract,
) -> StarknetContract:
    token_proxy = await session_starknet.deploy(
        PROXY_FILE,
        cairo_path=CAIRO_PATH,
        constructor_calldata=[UPGRADE_DELAY],
    )
    await token_proxy.init_governance().execute(caller_address=GOVERNOR_ADDRESS)
    l2_bridge_address = session_proxy_contract.contract_address
    declared_token_impl = await session_starknet.declare(
        ERC20_FILE,
        cairo_path=CAIRO_PATH,
    )
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
    await token_proxy.add_implementation(*proxy_func_params).execute(caller_address=GOVERNOR_ADDRESS)
    await token_proxy.upgrade_to(*proxy_func_params).execute(caller_address=GOVERNOR_ADDRESS)
    wrapped_token = token_proxy.replace_abi(impl_contract_abi=declared_token_impl.abi)

    # Initial balance setup.
    for account in initial_balances:
        await wrapped_token.permissionedMint(
            recipient=account, amount=Uint256(initial_balances[account]).uint256()
        ).execute(caller_address=l2_bridge_address)
    return wrapped_token


@pytest.fixture
async def starknet(
    session_starknet: Starknet, session_bridge_contract: StarknetContract
) -> Starknet:
    # Order enforcement. This way we enforce state clone only post proxy wiring.
    assert session_bridge_contract
    return copy.deepcopy(session_starknet)


@pytest.fixture(scope="module")
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
    await session_proxy_contract.add_implementation(*proxy_func_params).execute(
        caller_address=GOVERNOR_ADDRESS
    )
    await session_proxy_contract.upgrade_to(*proxy_func_params).execute(
        caller_address=GOVERNOR_ADDRESS
    )

    wrapped_bridge = session_proxy_contract.replace_abi(impl_contract_abi=declared_bridge_impl.abi)

    # Set L1 bridge address on the bridge.
    await wrapped_bridge.set_l1_bridge(l1_bridge_address=L1_BRIDGE_ADDRESS).execute(
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
    await wrapped_bridge.set_l2_token(l2_token_address=l2_token_address).execute(
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
    return StarknetContract(
        state=starknet.state,
        abi=session_bridge_contract.abi,
        contract_address=session_bridge_contract.contract_address,
        deploy_call_info=session_bridge_contract.deploy_call_info,
    )


@pytest.fixture
async def token_contract(
    starknet: Starknet, session_token_contract: StarknetContract
) -> StarknetContract:
    return StarknetContract(
        state=starknet.state,
        abi=session_token_contract.abi,
        contract_address=session_token_contract.contract_address,
        deploy_call_info=session_token_contract.deploy_call_info,
    )