import asyncio
import copy
import random

import pytest

from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME
from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.solidity.starknet_test_utils import Uint256
from starkware.starknet.std_contracts.ERC20.contracts import erc20_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.contracts import proxy_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.test_utils import advance_time
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

TRANSFER_EVENT = "Transfer"
APPROVAL_EVENT = "Approval"

def str_to_felt(short_text: str) -> int:
    felt = int.from_bytes(bytes(short_text, encoding="ascii"), "big")
    assert felt < DEFAULT_PRIME, f"{short_text} is too long"
    return felt


AMOUNT_BOUND = 2**256
GOVERNOR_ADDRESS = str_to_felt("GOVERNOR")
MINTER_ADDRESS = str_to_felt("MINTER")
L1_ACCOUNT = 1
TOKEN_CONTRACT_IDENTITY = "ERC20"
TOKEN_CONTRACT_VERSION = 1

initial_balances = {1: 13, 2: 10}
uninitialized_account = 3
initial_total_supply = sum(initial_balances.values())
initialized_account = random.choice(list(initial_balances.keys()))
another_account = 4  # Not initialized_account and not uninitialized_account.

# 0 < TRANSFER_AMOUNT < APPROVE_AMOUNT < initial_balance < HIGH_APPROVE_AMOUNT.
TRANSFER_AMOUNT = int((initial_balances[initialized_account] + 1) / 2)
APPROVE_AMOUNT = 8
HIGH_APPROVE_AMOUNT = 100
MINT_AMOUNT = 10
BURN_AMOUNT = int((initial_balances[initialized_account] + 1) / 2)
UPGRADE_DELAY = 0


def assert_last_event(
    starknet: Starknet,
    contract_: StarknetContract,
    event_name: str,
    from_: int,
    to_: int,
    amount: int,
):
    expected_event = Event(
        from_address=contract_.contract_address,
        keys=[get_selector_from_name(event_name)],
        data=[
            from_,
            to_,
            Uint256(amount).low,
            Uint256(amount).high,
        ],
    )
    assert expected_event == starknet.state.events[-1]


@pytest.fixture(scope="session")
def token_decimals() -> int:
    return 6


@pytest.fixture(scope="session")
def token_symbol() -> int:
    return str_to_felt("TKN")


@pytest.fixture(scope="session")
def token_name() -> int:
    return str_to_felt("TOKEN")


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
async def session_token_contract(
    session_starknet: Starknet,
    session_proxy_contract: StarknetContract,
    token_name: int,
    token_symbol: int,
    token_decimals: int,
) -> StarknetContract:
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
            MINTER_ADDRESS,
        ],
        NOT_FINAL,
    ]
    # Set a first implementation on the proxy.
    await session_proxy_contract.add_implementation(*proxy_func_params).invoke(
        caller_address=GOVERNOR_ADDRESS
    )
    await session_proxy_contract.upgrade_to(*proxy_func_params).invoke(
        caller_address=GOVERNOR_ADDRESS
    )
    wrapped_session_token = session_proxy_contract.replace_abi(
        impl_contract_abi=declared_token_impl.abi
    )

    # Initial balance setup.
    for account in initial_balances:
        await wrapped_session_token.permissionedMint(
            recipient=account, amount=Uint256(initial_balances[account]).uint256()
        ).invoke(caller_address=MINTER_ADDRESS)
    return wrapped_session_token


@pytest.fixture
async def starknet(
    session_starknet: Starknet, session_token_contract: StarknetContract
) -> Starknet:
    # Order enforcement. This way we enforce state clone only post proxy wiring.
    assert session_token_contract
    return copy.deepcopy(session_starknet)


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
async def test_token_wrapped_properly(
    session_token_contract: StarknetContract,
    token_contract: StarknetContract,
    session_proxy_contract: StarknetContract,
):
    token_impl = (await session_proxy_contract.implementation().call()).result[0]
    assert token_impl != 0
    assert session_token_contract.state is not token_contract.state
    assert token_contract.contract_address == session_proxy_contract.contract_address
    assert (await token_contract.initialized().call()).result[0] == True


@pytest.mark.asyncio
async def test_permitted_minter(token_contract: StarknetContract):
    execution_info = await token_contract.permittedMinter().call()
    assert execution_info.result == (MINTER_ADDRESS,)


@pytest.mark.asyncio
async def test_get_identity(token_contract: StarknetContract):
    execution_info = await token_contract.get_identity().call()
    assert execution_info.result[0] == str_to_felt(TOKEN_CONTRACT_IDENTITY)


@pytest.mark.asyncio
async def test_get_version(token_contract: StarknetContract):
    execution_info = await token_contract.get_version().call()
    assert execution_info.result[0] == TOKEN_CONTRACT_VERSION


@pytest.mark.asyncio
async def test_name(token_contract: StarknetContract, token_name: int):
    execution_info = await token_contract.name().call()
    assert execution_info.result == (token_name,)


@pytest.mark.asyncio
async def test_symbol(token_contract: StarknetContract, token_symbol: int):
    execution_info = await token_contract.symbol().call()
    assert execution_info.result == (token_symbol,)


@pytest.mark.asyncio
async def test_decimal(token_contract: StarknetContract, token_decimals: int):
    execution_info = await token_contract.decimals().call()
    assert execution_info.result == (token_decimals,)


@pytest.mark.asyncio
async def test_total_supply(token_contract: StarknetContract):
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == Uint256(initial_total_supply).uint256()


@pytest.mark.asyncio
async def test_balance_of(token_contract: StarknetContract):
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == Uint256(initial_balances[initialized_account]).uint256()
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result[0] == Uint256(0).uint256()


@pytest.mark.asyncio
async def test_transfer_zero_sender(token_contract: StarknetContract):
    amount = Uint256(TRANSFER_AMOUNT).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(sender\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=0
        )


@pytest.mark.asyncio
async def test_transfer_zero_recipient(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(recipient\)"):
        await token_contract.transfer(
            recipient=0, amount=Uint256(TRANSFER_AMOUNT).uint256()
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_transfer_amount_bigger_than_balance(token_contract: StarknetContract):
    amount = Uint256(initial_balances[initialized_account] + 1).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_balance\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_transfer_invalid_uint256_amount(token_contract: StarknetContract):
    amount = Uint256(AMOUNT_BOUND).uint256()
    with pytest.raises(StarkException, match=r"uint256_check\(amount\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_transfer_happy_flow(starknet: Starknet, token_contract: StarknetContract):
    transfer_amount = Uint256(TRANSFER_AMOUNT).uint256()

    await token_contract.transfer(recipient=uninitialized_account, amount=transfer_amount).invoke(
        caller_address=initialized_account
    )
    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=TRANSFER_EVENT,
        from_=initialized_account,
        to_=uninitialized_account,
        amount=TRANSFER_AMOUNT,
    )

    expected_balance = Uint256(initial_balances[initialized_account] - TRANSFER_AMOUNT).uint256()
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == expected_balance
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result[0] == transfer_amount
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == Uint256(initial_total_supply).uint256()

    await token_contract.transfer(recipient=initialized_account, amount=transfer_amount).invoke(
        caller_address=uninitialized_account
    )
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == Uint256(initial_balances[initialized_account]).uint256()
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result[0] == Uint256(0).uint256()

    # Tests the case of sender = recipient.
    await token_contract.transfer(recipient=initialized_account, amount=transfer_amount).invoke(
        caller_address=initialized_account
    )
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == Uint256(initial_balances[initialized_account]).uint256()


@pytest.mark.asyncio
async def test_approve_zero_owner(token_contract: StarknetContract):
    amount = Uint256(APPROVE_AMOUNT).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(caller\)"):
        await token_contract.approve(spender=uninitialized_account, amount=amount).invoke(
            caller_address=0
        )


@pytest.mark.asyncio
async def test_approve_zero_spender(token_contract: StarknetContract):
    amount = Uint256(APPROVE_AMOUNT).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(spender\)"):
        await token_contract.approve(spender=0, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_approve_invalid_uint256_amount(token_contract: StarknetContract):
    amount = Uint256(AMOUNT_BOUND).uint256()
    with pytest.raises(StarkException, match=r"uint256_check\(amount\)"):
        await token_contract.approve(spender=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_approve_happy_flow(starknet: Starknet, token_contract: StarknetContract):
    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result[0] == Uint256(0).uint256()
    approved_amount = Uint256(APPROVE_AMOUNT).uint256()
    await token_contract.approve(spender=uninitialized_account, amount=approved_amount).invoke(
        caller_address=initialized_account
    )

    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=APPROVAL_EVENT,
        from_=initialized_account,
        to_=uninitialized_account,
        amount=APPROVE_AMOUNT,
    )

    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result[0] == approved_amount


@pytest.mark.asyncio
async def test_transfer_from_zero_sender(token_contract: StarknetContract):
    # The contract fails when checking for sufficient allowance of account 0.
    # Only because we cannot put a balance for address(0) or approve on its behalf.
    # Could we do that, we would have failed on the more sensible error assert_not_zero(sender).
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=0, recipient=uninitialized_account, amount=Uint256(TRANSFER_AMOUNT).uint256()
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_zero_recipient(token_contract: StarknetContract):
    amount = Uint256(TRANSFER_AMOUNT).uint256()
    await token_contract.approve(spender=another_account, amount=amount).invoke(
        caller_address=initialized_account
    )
    with pytest.raises(StarkException, match=r"assert_not_zero\(recipient\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=0, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_amount_bigger_than_balance(token_contract: StarknetContract):
    await token_contract.approve(
        spender=another_account, amount=Uint256(HIGH_APPROVE_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)
    amount = Uint256(initial_balances[initialized_account] + 1).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_balance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_amount_bigger_than_allowance(token_contract: StarknetContract):
    await token_contract.approve(
        spender=another_account, amount=Uint256(APPROVE_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)
    amount = Uint256(APPROVE_AMOUNT + 1).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_invalid_uint256_amount(token_contract: StarknetContract):
    amount = Uint256(AMOUNT_BOUND).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
@pytest.mark.parametrize("approve_num", [APPROVE_AMOUNT, HIGH_APPROVE_AMOUNT])
async def test_transfer_from_happy_flow(
    starknet: Starknet, token_contract: StarknetContract, approve_num: int
):
    await token_contract.approve(
        spender=another_account, amount=Uint256(approve_num).uint256()
    ).invoke(caller_address=initialized_account)
    await token_contract.transferFrom(
        sender=initialized_account,
        recipient=uninitialized_account,
        amount=Uint256(TRANSFER_AMOUNT).uint256(),
    ).invoke(caller_address=another_account)
    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=TRANSFER_EVENT,
        from_=initialized_account,
        to_=uninitialized_account,
        amount=TRANSFER_AMOUNT,
    )


@pytest.mark.asyncio
async def test_increase_allowance_zero_spender(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(spender\)"):
        await token_contract.increaseAllowance(
            spender=0, added_value=Uint256(APPROVE_AMOUNT).uint256()
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_allowance_invalid_amount(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"uint256_check\(added_value\)"):
        await token_contract.increaseAllowance(
            spender=uninitialized_account, added_value=Uint256(AMOUNT_BOUND).uint256()
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_allowance_overflow(token_contract: StarknetContract):
    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=Uint256(APPROVE_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)
    with pytest.raises(StarkException, match=r"assert \(is_overflow\) = 0"):
        await token_contract.increaseAllowance(
            spender=uninitialized_account,
            added_value=Uint256(AMOUNT_BOUND - APPROVE_AMOUNT).uint256(),
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_decrease_allowance_zero_spender(token_contract: StarknetContract):
    approve_amount = Uint256(APPROVE_AMOUNT).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_allowance\)"):
        await token_contract.decreaseAllowance(spender=0, subtracted_value=approve_amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_decrease_allowance_bigger_than_allowance(token_contract: StarknetContract):
    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=Uint256(APPROVE_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_allowance\)"):
        await token_contract.decreaseAllowance(
            spender=uninitialized_account, subtracted_value=Uint256(APPROVE_AMOUNT + 1).uint256()
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_decrease_allowance_invalid_amount(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"uint256_check\(subtracted_value\)"):
        await token_contract.decreaseAllowance(
            spender=uninitialized_account, subtracted_value=Uint256(AMOUNT_BOUND).uint256()
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_and_decrease_allowance_happy_flow(
    starknet: Starknet, token_contract: StarknetContract
):
    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result[0] == Uint256(0).uint256()

    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=Uint256(APPROVE_AMOUNT).uint256()
    ).invoke(caller_address=initialized_account)
    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=APPROVAL_EVENT,
        from_=initialized_account,
        to_=uninitialized_account,
        amount=APPROVE_AMOUNT,
    )

    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result[0] == Uint256(APPROVE_AMOUNT).uint256()

    await token_contract.decreaseAllowance(
        spender=uninitialized_account, subtracted_value=Uint256(int(APPROVE_AMOUNT / 2)).uint256()
    ).invoke(caller_address=initialized_account)
    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=APPROVAL_EVENT,
        from_=initialized_account,
        to_=uninitialized_account,
        amount=APPROVE_AMOUNT // 2,
    )

    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result[0] == Uint256(APPROVE_AMOUNT - int(APPROVE_AMOUNT / 2)).uint256()


@pytest.mark.asyncio
async def test_permissioned_mint_wrong_minter(token_contract: StarknetContract):
    with pytest.raises(StarkException, match="assert caller_address = permitted_address"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=Uint256(MINT_AMOUNT).uint256()
        ).invoke(caller_address=MINTER_ADDRESS + 1)


@pytest.mark.asyncio
async def test_permissioned_mint_zero_recipient(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(recipient\)"):
        await token_contract.permissionedMint(
            recipient=0, amount=Uint256(MINT_AMOUNT).uint256()
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_mint_invalid_uint256_amount(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"uint256_check\(amount\)"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=Uint256(AMOUNT_BOUND).uint256()
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_mint_total_supply_out_of_range(token_contract: StarknetContract):
    amount = Uint256(AMOUNT_BOUND - initial_total_supply).uint256()
    with pytest.raises(StarkException, match=r"assert \(is_overflow\) = 0"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_mint_happy_flow(starknet: Starknet, token_contract: StarknetContract):
    await token_contract.permissionedMint(
        recipient=uninitialized_account, amount=Uint256(MINT_AMOUNT).uint256()
    ).invoke(caller_address=MINTER_ADDRESS)
    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=TRANSFER_EVENT,
        from_=0,
        to_=uninitialized_account,
        amount=MINT_AMOUNT,
    )

    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result[0] == Uint256(MINT_AMOUNT).uint256()
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == Uint256(initial_total_supply + MINT_AMOUNT).uint256()


@pytest.mark.asyncio
async def test_permissioned_burn_wrong_minter(token_contract: StarknetContract):
    with pytest.raises(StarkException, match="assert caller_address = permitted_address"):
        await token_contract.permissionedBurn(
            account=initialized_account, amount=Uint256(BURN_AMOUNT).uint256()
        ).invoke(caller_address=MINTER_ADDRESS + 1)


@pytest.mark.asyncio
async def test_permissioned_burn_zero_account(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"assert_not_zero\(account\)"):
        await token_contract.permissionedBurn(
            account=0, amount=Uint256(BURN_AMOUNT).uint256()
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_burn_invalid_uint256_amount(token_contract: StarknetContract):
    with pytest.raises(StarkException, match=r"uint256_check\(amount\)"):
        await token_contract.permissionedBurn(
            account=initialized_account, amount=Uint256(AMOUNT_BOUND).uint256()
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_burn_amount_bigger_than_balance(token_contract: StarknetContract):
    amount = Uint256(initial_balances[initialized_account] + 1).uint256()
    with pytest.raises(StarkException, match=r"assert_not_zero\(enough_balance\)"):
        await token_contract.permissionedBurn(account=initialized_account, amount=amount).invoke(
            caller_address=MINTER_ADDRESS
        )


@pytest.mark.asyncio
async def test_permissioned_burn_happy_flow(starknet: Starknet, token_contract: StarknetContract):
    await token_contract.permissionedMint(
        recipient=initialized_account, amount=Uint256(MINT_AMOUNT).uint256()
    ).invoke(caller_address=MINTER_ADDRESS)
    await token_contract.permissionedBurn(
        account=initialized_account, amount=Uint256(BURN_AMOUNT).uint256()
    ).invoke(caller_address=MINTER_ADDRESS)

    assert_last_event(
        starknet=starknet,
        contract_=token_contract,
        event_name=TRANSFER_EVENT,
        from_=initialized_account,
        to_=0,
        amount=BURN_AMOUNT,
    )

    expected_balance = Uint256(
        initial_balances[initialized_account] + MINT_AMOUNT - BURN_AMOUNT
    ).uint256()
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result[0] == expected_balance
    expected_supply = Uint256(initial_total_supply + MINT_AMOUNT - BURN_AMOUNT).uint256()
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result[0] == expected_supply
