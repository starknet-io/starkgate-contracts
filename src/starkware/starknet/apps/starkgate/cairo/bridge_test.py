import asyncio
import copy
import random
from typing import Callable

import pytest

from starkware.starknet.apps.starkgate.cairo.contracts import (
    bridge_contract_def,
    erc20_contract_def,
)
from starkware.starknet.apps.starkgate.conftest import str_to_felt
from starkware.starknet.compiler.compile import get_selector_from_name
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

ETH_ADDRESS_BOUND = 2 ** 160
GOVERNOR_ADDRESS = str_to_felt("GOVERNOR")
L1_BRIDGE_ADDRESS = 42
L1_ACCOUNT = 1

initial_balances = {1: 13, 2: 10}
uninitialized_account = 3
initial_total_supply = sum(initial_balances.values())
initialized_account = random.choice(list(initial_balances.keys()))


# 0 < BURN_AMOUNT < MINT_AMOUNT.
MINT_AMOUNT = 15
BURN_AMOUNT = MINT_AMOUNT - 1


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    return await Starknet.empty()


@pytest.fixture(scope="session")
async def session_uninitialized_bridge_contract(session_starknet: Starknet) -> StarknetContract:
    return await session_starknet.deploy(
        constructor_calldata=[GOVERNOR_ADDRESS], contract_def=bridge_contract_def
    )


@pytest.fixture(scope="session")
async def session_empty_token_contract(
    session_starknet: Starknet,
    token_name: int,
    token_symbol: int,
    token_decimals: int,
    session_uninitialized_bridge_contract: StarknetContract,
) -> StarknetContract:
    return await session_starknet.deploy(
        constructor_calldata=[
            token_name,
            token_symbol,
            token_decimals,
            session_uninitialized_bridge_contract.contract_address,
        ],
        contract_def=erc20_contract_def,
    )


@pytest.fixture(scope="session")
async def uint256(session_empty_token_contract: StarknetContract) -> Callable:
    def convert_int_to_uint256(num: int):
        if num < 0:
            num += 2 ** 256
        return session_empty_token_contract.Uint256(low=num % 2 ** 128, high=num // 2 ** 128)

    return convert_int_to_uint256


@pytest.fixture(scope="session")
async def session_bridge_contract(
    session_uninitialized_bridge_contract: StarknetContract,
    session_empty_token_contract: StarknetContract,
):
    await session_uninitialized_bridge_contract.set_l1_bridge(
        l1_bridge_address=L1_BRIDGE_ADDRESS
    ).invoke(caller_address=GOVERNOR_ADDRESS)

    await session_uninitialized_bridge_contract.set_l2_token(
        l2_token_address=session_empty_token_contract.contract_address
    ).invoke(caller_address=GOVERNOR_ADDRESS)

    return session_uninitialized_bridge_contract


@pytest.fixture(scope="session")
async def session_token_contract(
    session_empty_token_contract: StarknetContract,
    session_bridge_contract: StarknetContract,
    uint256: Callable,
) -> StarknetContract:
    for account in initial_balances:
        await session_empty_token_contract.permissionedMint(
            recipient=account, amount=uint256(initial_balances[account])
        ).invoke(caller_address=session_bridge_contract.contract_address)

    return session_empty_token_contract


@pytest.fixture
async def starknet(session_starknet: Starknet) -> Starknet:
    return copy.deepcopy(session_starknet)


@pytest.fixture
async def bridge_contract(
    starknet: Starknet, session_bridge_contract: StarknetContract
) -> StarknetContract:
    return StarknetContract(
        state=starknet.state,
        abi=bridge_contract_def.abi,
        contract_address=session_bridge_contract.contract_address,
        deploy_execution_info=session_bridge_contract.deploy_execution_info,
    )


@pytest.fixture
async def token_contract(
    starknet: Starknet, session_token_contract: StarknetContract
) -> StarknetContract:
    return StarknetContract(
        state=starknet.state,
        abi=erc20_contract_def.abi,
        contract_address=session_token_contract.contract_address,
        deploy_execution_info=session_token_contract.deploy_execution_info,
    )


@pytest.mark.asyncio
async def test_get_governor(bridge_contract: StarknetContract):
    execution_info = await bridge_contract.get_governor().call()
    assert execution_info.result == (GOVERNOR_ADDRESS,)


@pytest.mark.asyncio
async def test_get_l1_bridge(bridge_contract: StarknetContract, token_contract: StarknetContract):
    execution_info = await bridge_contract.get_l1_bridge().call()
    assert execution_info.result == (L1_BRIDGE_ADDRESS,)


@pytest.mark.asyncio
async def test_get_l2_token(bridge_contract: StarknetContract, token_contract: StarknetContract):
    execution_info = await bridge_contract.get_l2_token().call()
    assert execution_info.result == (token_contract.contract_address,)


@pytest.mark.asyncio
async def test_handle_deposit_wrong_l1_address(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    with pytest.raises(StarkException, match="assert from_address = expected_from_address"):
        await starknet.send_message_to_l2(
            from_address=L1_BRIDGE_ADDRESS + 1,
            to_address=bridge_contract.contract_address,
            selector=get_selector_from_name("handle_deposit"),
            payload=[initialized_account, uint256(MINT_AMOUNT).low, uint256(MINT_AMOUNT).high],
        )


@pytest.mark.asyncio
async def test_handle_deposit_zero_account(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    with pytest.raises(StarkException, match="assert_not_zero\(recipient\)"):
        await starknet.send_message_to_l2(
            from_address=L1_BRIDGE_ADDRESS,
            to_address=bridge_contract.contract_address,
            selector=get_selector_from_name("handle_deposit"),
            payload=[0, uint256(MINT_AMOUNT).low, uint256(MINT_AMOUNT).high],
        )


@pytest.mark.asyncio
async def test_handle_deposit_total_supply_out_of_range(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    amount = uint256(2 ** 256 - initial_total_supply)
    with pytest.raises(StarkException, match="assert \(is_overflow\) = 0"):
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
    uint256: Callable,
):
    await starknet.send_message_to_l2(
        from_address=L1_BRIDGE_ADDRESS,
        to_address=bridge_contract.contract_address,
        selector=get_selector_from_name("handle_deposit"),
        payload=[uninitialized_account, uint256(MINT_AMOUNT).low, uint256(MINT_AMOUNT).high],
    )
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result == (uint256(MINT_AMOUNT),)
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply + MINT_AMOUNT),)


@pytest.mark.asyncio
async def test_initiate_withdraw_invalid_l1_recipient(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    with pytest.raises(StarkException, match="assert_lt_felt\(l1_recipient, ETH_ADDRESS_BOUND\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=ETH_ADDRESS_BOUND, amount=uint256(initial_balances[initialized_account])
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_initiate_withdraw_zero_account(
    token_contract: StarknetContract, bridge_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match="assert_not_zero\(account\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=L1_ACCOUNT, amount=uint256(BURN_AMOUNT)
        ).invoke(caller_address=0)


@pytest.mark.asyncio
async def test_initiate_withdraw_amount_bigger_than_balance(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    with pytest.raises(StarkException, match="assert_not_zero\(enough_balance\)"):
        await bridge_contract.initiate_withdraw(
            l1_recipient=L1_ACCOUNT, amount=uint256(initial_balances[initialized_account] + 1)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_initiate_withdraw_happy_flow(
    starknet: Starknet,
    token_contract: StarknetContract,
    bridge_contract: StarknetContract,
    uint256: Callable,
):
    await starknet.send_message_to_l2(
        from_address=L1_BRIDGE_ADDRESS,
        to_address=bridge_contract.contract_address,
        selector=get_selector_from_name("handle_deposit"),
        payload=[initialized_account, uint256(MINT_AMOUNT).low, uint256(MINT_AMOUNT).high],
    )
    await bridge_contract.initiate_withdraw(
        l1_recipient=L1_ACCOUNT, amount=uint256(BURN_AMOUNT)
    ).invoke(caller_address=initialized_account)
    expected_balance = uint256(initial_balances[initialized_account] + MINT_AMOUNT - BURN_AMOUNT)
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (expected_balance,)
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply + MINT_AMOUNT - BURN_AMOUNT),)
