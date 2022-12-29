import random

import pytest

from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from test.utils import str_to_felt, Uint256


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
    ).execute(caller_address=initialized_account)

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
