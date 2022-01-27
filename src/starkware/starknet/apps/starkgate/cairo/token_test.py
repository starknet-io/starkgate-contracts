import asyncio
import copy
import random
from typing import Callable

import pytest

from starkware.starknet.apps.starkgate.cairo.contracts import erc20_contract_def
from starkware.starknet.apps.starkgate.conftest import str_to_felt
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

AMOUNT_BOUND = 2 ** 256
GOVERNOR_ADDRESS = str_to_felt("GOVERNOR")
MINTER_ADDRESS = str_to_felt("MINTER")
L1_ACCOUNT = 1

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


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session")
async def session_starknet() -> Starknet:
    return await Starknet.empty()


@pytest.fixture(scope="session")
async def session_empty_token_contract(
    session_starknet: Starknet,
    token_name: int,
    token_symbol: int,
    token_decimals: int,
) -> StarknetContract:
    return await session_starknet.deploy(
        constructor_calldata=[
            token_name,
            token_symbol,
            token_decimals,
            MINTER_ADDRESS,
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
async def session_token_contract(
    session_empty_token_contract: StarknetContract,
    uint256: Callable,
) -> StarknetContract:
    for account in initial_balances:
        await session_empty_token_contract.permissionedMint(
            recipient=account, amount=uint256(initial_balances[account])
        ).invoke(caller_address=MINTER_ADDRESS)

    return session_empty_token_contract


@pytest.fixture
async def starknet(session_starknet: Starknet) -> Starknet:
    return copy.deepcopy(session_starknet)


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
async def test_permitted_minter(token_contract: StarknetContract):
    execution_info = await token_contract.permittedMinter().call()
    assert execution_info.result == (MINTER_ADDRESS,)


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
async def test_total_supply(token_contract: StarknetContract, uint256: Callable):
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply),)


@pytest.mark.asyncio
async def test_balance_of(token_contract: StarknetContract, uint256: Callable):
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (uint256(initial_balances[initialized_account]),)
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result == (uint256(0),)


@pytest.mark.asyncio
async def test_transfer_zero_sender(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(TRANSFER_AMOUNT)
    with pytest.raises(StarkException, match="assert_not_zero\(sender\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=0
        )


@pytest.mark.asyncio
async def test_transfer_zero_recipient(token_contract: StarknetContract, uint256: Callable):
    with pytest.raises(StarkException, match="assert_not_zero\(recipient\)"):
        await token_contract.transfer(recipient=0, amount=uint256(TRANSFER_AMOUNT)).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_transfer_amount_bigger_than_balance(
    token_contract: StarknetContract, uint256: Callable
):
    amount = uint256(initial_balances[initialized_account] + 1)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_balance\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_transfer_invalid_uint256_amount(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(AMOUNT_BOUND)
    with pytest.raises(StarkException, match="uint256_check\(amount\)"):
        await token_contract.transfer(recipient=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_transfer_happy_flow(token_contract: StarknetContract, uint256: Callable):
    transfer_amount = uint256(TRANSFER_AMOUNT)
    await token_contract.transfer(recipient=uninitialized_account, amount=transfer_amount).invoke(
        caller_address=initialized_account
    )
    expected_balance = uint256(initial_balances[initialized_account] - TRANSFER_AMOUNT)
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (expected_balance,)
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result == (transfer_amount,)
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply),)

    await token_contract.transfer(recipient=initialized_account, amount=transfer_amount).invoke(
        caller_address=uninitialized_account
    )
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (uint256(initial_balances[initialized_account]),)
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result == (uint256(0),)

    # Tests the case of sender = recipient.
    await token_contract.transfer(recipient=initialized_account, amount=transfer_amount).invoke(
        caller_address=initialized_account
    )
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (uint256(initial_balances[initialized_account]),)


@pytest.mark.asyncio
async def test_approve_zero_owner(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(APPROVE_AMOUNT)
    with pytest.raises(StarkException, match="assert_not_zero\(caller\)"):
        await token_contract.approve(spender=uninitialized_account, amount=amount).invoke(
            caller_address=0
        )


@pytest.mark.asyncio
async def test_approve_zero_spender(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(APPROVE_AMOUNT)
    with pytest.raises(StarkException, match="assert_not_zero\(spender\)"):
        await token_contract.approve(spender=0, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_approve_invalid_uint256_amount(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(AMOUNT_BOUND)
    with pytest.raises(StarkException, match="uint256_check\(amount\)"):
        await token_contract.approve(spender=uninitialized_account, amount=amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_approve_happy_flow(token_contract: StarknetContract, uint256: Callable):
    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result == (uint256(0),)
    await token_contract.approve(
        spender=uninitialized_account, amount=uint256(APPROVE_AMOUNT)
    ).invoke(caller_address=initialized_account)
    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result == (uint256(APPROVE_AMOUNT),)


@pytest.mark.asyncio
async def test_transfer_from_zero_sender(token_contract: StarknetContract, uint256: Callable):
    # The contract fails when checking for sufficient allowance of account 0.
    # Only because we cannot put a balance for address(0) or approve on its behalf.
    # Could we do that, we would have failed on the more sensible error assert_not_zero(sender).
    with pytest.raises(StarkException, match="assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=0, recipient=uninitialized_account, amount=uint256(TRANSFER_AMOUNT)
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_zero_recipient(token_contract: StarknetContract, uint256: Callable):
    amount = uint256(TRANSFER_AMOUNT)
    await token_contract.approve(spender=another_account, amount=uint256(TRANSFER_AMOUNT)).invoke(
        caller_address=initialized_account
    )
    with pytest.raises(StarkException, match="assert_not_zero\(recipient\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=0, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_amount_bigger_than_balance(
    token_contract: StarknetContract, uint256: Callable
):
    await token_contract.approve(
        spender=another_account, amount=uint256(HIGH_APPROVE_AMOUNT)
    ).invoke(caller_address=initialized_account)
    amount = uint256(initial_balances[initialized_account] + 1)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_balance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_amount_bigger_than_allowance(
    token_contract: StarknetContract, uint256: Callable
):
    await token_contract.approve(spender=another_account, amount=uint256(APPROVE_AMOUNT)).invoke(
        caller_address=initialized_account
    )
    amount = uint256(APPROVE_AMOUNT + 1)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_transfer_from_invalid_uint256_amount(
    token_contract: StarknetContract, uint256: Callable
):
    amount = uint256(AMOUNT_BOUND)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_allowance\)"):
        await token_contract.transferFrom(
            sender=initialized_account, recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=another_account)


@pytest.mark.asyncio
@pytest.mark.parametrize("approve_num", [APPROVE_AMOUNT, HIGH_APPROVE_AMOUNT])
async def test_transfer_from_happy_flow(
    token_contract: StarknetContract, uint256: Callable, approve_num: int
):
    await token_contract.approve(spender=another_account, amount=uint256(approve_num)).invoke(
        caller_address=initialized_account
    )
    await token_contract.transferFrom(
        sender=initialized_account, recipient=uninitialized_account, amount=uint256(TRANSFER_AMOUNT)
    ).invoke(caller_address=another_account)


@pytest.mark.asyncio
async def test_increase_allowance_zero_spender(token_contract: StarknetContract, uint256: Callable):
    with pytest.raises(StarkException, match="assert_not_zero\(spender\)"):
        await token_contract.increaseAllowance(
            spender=0, added_value=uint256(APPROVE_AMOUNT)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_allowance_invalid_amount(
    token_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match="uint256_check\(added_value\)"):
        await token_contract.increaseAllowance(
            spender=uninitialized_account, added_value=uint256(AMOUNT_BOUND)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_allowance_overflow(token_contract: StarknetContract, uint256: Callable):
    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=uint256(APPROVE_AMOUNT)
    ).invoke(caller_address=initialized_account)
    with pytest.raises(StarkException, match="assert \(is_overflow\) = 0"):
        await token_contract.increaseAllowance(
            spender=uninitialized_account, added_value=uint256(AMOUNT_BOUND - APPROVE_AMOUNT)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_decrease_allowance_zero_spender(token_contract: StarknetContract, uint256: Callable):
    approve_amount = uint256(APPROVE_AMOUNT)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_allowance\)"):
        await token_contract.decreaseAllowance(spender=0, subtracted_value=approve_amount).invoke(
            caller_address=initialized_account
        )


@pytest.mark.asyncio
async def test_decrease_allowance_bigger_than_allowance(
    token_contract: StarknetContract, uint256: Callable
):
    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=uint256(APPROVE_AMOUNT)
    ).invoke(caller_address=initialized_account)
    with pytest.raises(StarkException, match="assert_not_zero\(enough_allowance\)"):
        await token_contract.decreaseAllowance(
            spender=uninitialized_account, subtracted_value=uint256(APPROVE_AMOUNT + 1)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_decrease_allowance_invalid_amount(
    token_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match="uint256_check\(subtracted_value\)"):
        await token_contract.decreaseAllowance(
            spender=uninitialized_account, subtracted_value=uint256(AMOUNT_BOUND)
        ).invoke(caller_address=initialized_account)


@pytest.mark.asyncio
async def test_increase_and_decrease_allowance_happy_flow(
    token_contract: StarknetContract, uint256: Callable
):
    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result == (uint256(0),)

    await token_contract.increaseAllowance(
        spender=uninitialized_account, added_value=uint256(APPROVE_AMOUNT)
    ).invoke(caller_address=initialized_account)

    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result == (uint256(APPROVE_AMOUNT),)

    await token_contract.decreaseAllowance(
        spender=uninitialized_account, subtracted_value=uint256(int(APPROVE_AMOUNT / 2))
    ).invoke(caller_address=initialized_account)

    execution_info = await token_contract.allowance(
        owner=initialized_account, spender=uninitialized_account
    ).call()
    assert execution_info.result == (uint256(APPROVE_AMOUNT - int(APPROVE_AMOUNT / 2)),)


@pytest.mark.asyncio
async def test_permissioned_mint_wrong_minter(token_contract: StarknetContract, uint256: Callable):
    with pytest.raises(StarkException, match="assert caller_address = permitted_address"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=uint256(MINT_AMOUNT)
        ).invoke(caller_address=MINTER_ADDRESS + 1)


@pytest.mark.asyncio
async def test_permissioned_mint_zero_recipient(
    token_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match="assert_not_zero\(recipient\)"):
        await token_contract.permissionedMint(recipient=0, amount=uint256(MINT_AMOUNT)).invoke(
            caller_address=MINTER_ADDRESS
        )


@pytest.mark.asyncio
async def test_permissioned_mint_invalid_uint256_amount(
    token_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match=f"uint256_check\(amount\)"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=uint256(AMOUNT_BOUND)
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_mint_total_supply_out_of_range(
    token_contract: StarknetContract, uint256: Callable
):
    amount = uint256(AMOUNT_BOUND - initial_total_supply)
    with pytest.raises(StarkException, match=f"assert \(is_overflow\) = 0"):
        await token_contract.permissionedMint(
            recipient=uninitialized_account, amount=amount
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_mint_happy_flow(token_contract: StarknetContract, uint256: Callable):
    await token_contract.permissionedMint(
        recipient=uninitialized_account, amount=uint256(MINT_AMOUNT)
    ).invoke(caller_address=MINTER_ADDRESS)
    execution_info = await token_contract.balanceOf(account=uninitialized_account).call()
    assert execution_info.result == (uint256(MINT_AMOUNT),)
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply + MINT_AMOUNT),)


@pytest.mark.asyncio
async def test_permissioned_burn_wrong_minter(token_contract: StarknetContract, uint256: Callable):
    with pytest.raises(StarkException, match="assert caller_address = permitted_address"):
        await token_contract.permissionedBurn(
            account=initialized_account, amount=uint256(BURN_AMOUNT)
        ).invoke(caller_address=MINTER_ADDRESS + 1)


@pytest.mark.asyncio
async def test_permissioned_burn_zero_account(token_contract: StarknetContract, uint256: Callable):
    with pytest.raises(StarkException, match="assert_not_zero\(account\)"):
        await token_contract.permissionedBurn(account=0, amount=uint256(BURN_AMOUNT)).invoke(
            caller_address=MINTER_ADDRESS
        )


@pytest.mark.asyncio
async def test_permissioned_burn_invalid_uint256_amount(
    token_contract: StarknetContract, uint256: Callable
):
    with pytest.raises(StarkException, match=f"uint256_check\(amount\)"):
        await token_contract.permissionedBurn(
            account=initialized_account, amount=uint256(AMOUNT_BOUND)
        ).invoke(caller_address=MINTER_ADDRESS)


@pytest.mark.asyncio
async def test_permissioned_burn_amount_bigger_than_balance(
    token_contract: StarknetContract, uint256: Callable
):
    amount = uint256(initial_balances[initialized_account] + 1)
    with pytest.raises(StarkException, match=f"assert_not_zero\(enough_balance\)"):
        await token_contract.permissionedBurn(account=initialized_account, amount=amount).invoke(
            caller_address=MINTER_ADDRESS
        )


@pytest.mark.asyncio
async def test_permissioned_burn_happy_flow(token_contract: StarknetContract, uint256: Callable):
    await token_contract.permissionedMint(
        recipient=initialized_account, amount=uint256(MINT_AMOUNT)
    ).invoke(caller_address=MINTER_ADDRESS)
    await token_contract.permissionedBurn(
        account=initialized_account, amount=uint256(BURN_AMOUNT)
    ).invoke(caller_address=MINTER_ADDRESS)
    expected_balance = uint256(initial_balances[initialized_account] + MINT_AMOUNT - BURN_AMOUNT)
    execution_info = await token_contract.balanceOf(account=initialized_account).call()
    assert execution_info.result == (expected_balance,)
    execution_info = await token_contract.totalSupply().call()
    assert execution_info.result == (uint256(initial_total_supply + MINT_AMOUNT - BURN_AMOUNT),)
