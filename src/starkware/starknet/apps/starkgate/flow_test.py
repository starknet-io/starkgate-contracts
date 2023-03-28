import pytest
import pytest_asyncio

from starkware.eth.eth_test_utils import EthContract, EthTestUtils
from starkware.starknet.apps.starkgate.cairo.contracts import bridge_contract_class
from starkware.starknet.apps.starkgate.conftest import TokenBridgeWrapper
from starkware.starknet.solidity.starknet_test_utils import Uint256
from starkware.starknet.std_contracts.ERC20.contracts import erc20_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.contracts import proxy_contract_class
from starkware.starknet.std_contracts.upgradability_proxy.test_utils import advance_time
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.postman import Postman

AMOUNT = 10
L2_ADDRESS1 = 341
L2_ADDRESS2 = 737
L2_GOVERNANCE_ADDRESS = 651
UPGRADE_DELAY = 0
MAX_TOTAL_BALANCE_AMOUNT = (2**256) - 1
MAX_DEPOSIT_AMOUNT = (2**256) - 1


@pytest_asyncio.fixture
async def postman(eth_test_utils: EthTestUtils) -> Postman:
    postmen = await Postman.create(eth_test_utils=eth_test_utils)
    # We need to  advance the clock. Proxy relies on timestamp be gt 0.
    advance_time(starknet=postmen.starknet, block_time_diff=1, block_num_diff=1)
    return postmen


# This fixture is needed for the `token_bridge_wrapper` fixture.
@pytest.fixture
def mock_starknet_messaging_contract(postman) -> EthContract:
    return postman.mock_starknet_messaging_contract


@pytest_asyncio.fixture
async def l2_token_contract(
    postman, token_name, token_symbol, token_decimals, l2_token_bridge_contract
) -> StarknetContract:
    starknet = postman.starknet
    token_proxy = await starknet.deploy(
        constructor_calldata=[UPGRADE_DELAY], contract_class=proxy_contract_class
    )
    await token_proxy.init_governance().execute(caller_address=L2_GOVERNANCE_ADDRESS)

    declared_token_impl = await starknet.declare(contract_class=erc20_contract_class)
    NOT_FINAL = False
    NO_EIC = 0
    proxy_func_params = [
        declared_token_impl.class_hash,
        NO_EIC,
        [
            token_name,
            token_symbol,
            token_decimals,
            l2_token_bridge_contract.contract_address,
        ],
        NOT_FINAL,
    ]
    # Set a first implementation on the proxy.
    await token_proxy.add_implementation(*proxy_func_params).execute(
        caller_address=L2_GOVERNANCE_ADDRESS
    )
    await token_proxy.upgrade_to(*proxy_func_params).execute(caller_address=L2_GOVERNANCE_ADDRESS)
    return token_proxy.replace_abi(impl_contract_abi=declared_token_impl.abi)


@pytest_asyncio.fixture
async def l2_token_bridge_contract(postman) -> StarknetContract:
    """
    As the token_bridge is deployed behind a proxy,
    this fixture does all of this:
    1. Deploy the token_bridge contract.
    2. Deploy the proxy contract.
    3. Put the bridge behind the proxy.
    """
    starknet = postman.starknet
    declared_bridge_impl = await starknet.declare(contract_class=bridge_contract_class)
    proxy_impl = await starknet.deploy(
        constructor_calldata=[UPGRADE_DELAY], contract_class=proxy_contract_class
    )
    await proxy_impl.init_governance().execute(caller_address=L2_GOVERNANCE_ADDRESS)

    # Create convenience arguments for proxy calls.
    int_vec = [L2_GOVERNANCE_ADDRESS]
    NOT_FINAL = False
    NO_EIC = 0
    proxy_func_params = [
        declared_bridge_impl.class_hash,
        NO_EIC,
        int_vec,
        NOT_FINAL,
    ]

    # Wrap the deployed bridge with the proxy (addImpl & upgradeTo).
    await proxy_impl.add_implementation(*proxy_func_params).execute(
        caller_address=L2_GOVERNANCE_ADDRESS
    )
    await proxy_impl.upgrade_to(*proxy_func_params).execute(caller_address=L2_GOVERNANCE_ADDRESS)

    # Create a contract object of the bridge abi, and proxy's address & state.
    return proxy_impl.replace_abi(impl_contract_abi=declared_bridge_impl.abi)


async def configure_bridge_contracts(
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
    max_total_balance_amount: int = MAX_TOTAL_BALANCE_AMOUNT,
    max_deposit_amount: int = MAX_DEPOSIT_AMOUNT,
):

    l1_token_bridge_contract = token_bridge_wrapper.contract

    # Connect between contracts.
    l1_token_bridge_contract.setL2TokenBridge.transact(
        l2_token_bridge_contract.contract_address,
        transact_args={"from": token_bridge_wrapper.default_user},
    )
    await l2_token_bridge_contract.set_l1_bridge(
        l1_bridge_address=int(l1_token_bridge_contract.address, 16)
    ).execute(caller_address=L2_GOVERNANCE_ADDRESS)
    await l2_token_bridge_contract.set_l2_token(
        l2_token_address=l2_token_contract.contract_address
    ).execute(caller_address=L2_GOVERNANCE_ADDRESS)

    # Setup caps.
    l1_token_bridge_contract.setMaxTotalBalance.transact(
        max_total_balance_amount, transact_args={"from": token_bridge_wrapper.default_user}
    )
    l1_token_bridge_contract.setMaxDeposit.transact(
        max_deposit_amount, transact_args={"from": token_bridge_wrapper.default_user}
    )


@pytest.mark.parametrize(
    "deposit_max_amount", [False, True], ids=["simple_deposit", "deposit_max_amount"]
)
@pytest.mark.parametrize("fee", [0, 1000], ids=["no_fee", "with_fee"])
@pytest.mark.asyncio
async def test_token_positive_flow(
    postman: Postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
    fee: int,
    deposit_max_amount: bool,
):
    await configure_bridge_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        l2_token_contract=l2_token_contract,
        l2_token_bridge_contract=l2_token_bridge_contract,
        max_deposit_amount=AMOUNT if deposit_max_amount else MAX_DEPOSIT_AMOUNT,
    )

    # Deposit AMOUNT to L2.
    l1_sender = token_bridge_wrapper.default_user
    l1_sender_initial_balance = token_bridge_wrapper.get_account_balance(l1_sender)
    assert l1_sender_initial_balance >= AMOUNT + token_bridge_wrapper.TRANSACTION_COSTS_BOUND

    tx_receipt = token_bridge_wrapper.deposit(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, user=l1_sender, fee=fee
    )

    assert token_bridge_wrapper.get_account_balance(l1_sender) == (
        l1_sender_initial_balance - AMOUNT - token_bridge_wrapper.get_tx_cost(tx_receipt)
    )
    assert token_bridge_wrapper.get_bridge_balance() == AMOUNT

    await postman.flush()

    # Check the result.
    execution_info = await l2_token_contract.balanceOf(account=L2_ADDRESS1).execute()
    assert execution_info.result == (
        l2_token_contract.Uint256(low=AMOUNT % (2**128), high=AMOUNT // (2**128)),
    )

    # Perform a transfer inside L2.
    uint256_amount = l2_token_contract.Uint256(low=AMOUNT % (2**128), high=AMOUNT // (2**128))
    await l2_token_contract.transfer(recipient=L2_ADDRESS2, amount=uint256_amount).execute(
        caller_address=L2_ADDRESS1
    )

    l1_recipient = token_bridge_wrapper.non_default_user
    l1_recipient_initial_balance = token_bridge_wrapper.get_account_balance(l1_recipient)

    # Withdraw AMOUNT to L1.
    await l2_token_bridge_contract.initiate_withdraw(
        l1_recipient=int(l1_recipient.address, 16), amount=uint256_amount
    ).execute(caller_address=L2_ADDRESS2)
    await postman.flush()
    token_bridge_wrapper.withdraw(amount=AMOUNT, user=l1_recipient)

    # Assert balances.
    assert token_bridge_wrapper.get_account_balance(l1_recipient) == (
        l1_recipient_initial_balance + AMOUNT
    )
    assert token_bridge_wrapper.get_bridge_balance() == 0


@pytest.mark.parametrize("fee", [0, 1000], ids=["no_fee", "with_fee"])
@pytest.mark.asyncio
async def test_deposit_cancel_reclaim(
    postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
    fee: int,
):
    await configure_bridge_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        l2_token_contract=l2_token_contract,
        l2_token_bridge_contract=l2_token_bridge_contract,
    )

    # Deposit AMOUNT to L2.
    l1_sender = token_bridge_wrapper.default_user
    l1_sender_initial_balance = token_bridge_wrapper.get_account_balance(l1_sender)
    assert l1_sender_initial_balance >= AMOUNT + token_bridge_wrapper.TRANSACTION_COSTS_BOUND

    token_bridge_wrapper.deposit(amount=AMOUNT, l2_recipient=L2_ADDRESS1, user=l1_sender, fee=fee)

    assert token_bridge_wrapper.get_bridge_balance() == AMOUNT

    token_bridge_wrapper.deposit_cancel_request(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, nonce=0, user=l1_sender
    )
    token_bridge_wrapper.deposit_reclaim(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, nonce=0, user=l1_sender
    )

    with pytest.raises(Exception, match="INVALID_MESSAGE_TO_CONSUME"):
        await postman.flush()


@pytest.mark.parametrize("fee", [0, 1000], ids=["no_fee", "with_fee"])
@pytest.mark.asyncio
async def test_withdraw_twice(
    postman: Postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
    fee: int,
):
    """
    Deposit deposited_amount to L2 and perform two L2 withdraws of (deposited_amount / 2). Assert
    one L1 withdrawal of deposited_amount fails, that two L1 withdrawals of
    (deposited_amount / 2) succeed (with correct balances after each withdrawal) and that a third
    L1 withdrawal of (deposited_amount / 2) fails.
    """
    each_withdrawal_amount = AMOUNT
    deposited_amount = each_withdrawal_amount * 2

    python_uint256_each_withdrawal_amount = Uint256(num=each_withdrawal_amount)
    python_uint256_deposit_amount = Uint256(num=deposited_amount)
    uint256_each_withdrawal_amount = l2_token_contract.Uint256(
        low=python_uint256_each_withdrawal_amount.low,
        high=python_uint256_each_withdrawal_amount.high,
    )
    uint256_deposited_amount = l2_token_contract.Uint256(
        low=python_uint256_deposit_amount.low, high=python_uint256_deposit_amount.high
    )

    await configure_bridge_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        l2_token_contract=l2_token_contract,
        l2_token_bridge_contract=l2_token_bridge_contract,
    )

    # Deposit deposited_amount to L2.
    l1_sender = token_bridge_wrapper.default_user
    l1_sender_initial_balance = token_bridge_wrapper.get_account_balance(l1_sender)
    assert (
        l1_sender_initial_balance >= deposited_amount + token_bridge_wrapper.TRANSACTION_COSTS_BOUND
    )
    tx_receipt = token_bridge_wrapper.deposit(
        amount=deposited_amount, l2_recipient=L2_ADDRESS1, user=l1_sender, fee=fee
    )

    # Assert the L1 balances have been updated after the deposit.
    assert token_bridge_wrapper.get_account_balance(l1_sender) == (
        l1_sender_initial_balance - deposited_amount - token_bridge_wrapper.get_tx_cost(tx_receipt)
    )
    assert token_bridge_wrapper.get_bridge_balance() == deposited_amount

    # Assert recipient account's L2 balance has been updated after the deposit.
    await postman.flush()
    execution_info = await l2_token_contract.balanceOf(account=L2_ADDRESS1).execute()
    assert execution_info.result == (uint256_deposited_amount,)

    # Perform two L2 withdrawals of each_withdrawal_amount.
    l1_recipient = token_bridge_wrapper.non_default_user
    l1_recipient_initial_balance = token_bridge_wrapper.get_account_balance(l1_recipient)
    for _ in range(2):
        await l2_token_bridge_contract.initiate_withdraw(
            l1_recipient=int(l1_recipient.address, 16), amount=uint256_each_withdrawal_amount
        ).execute(caller_address=L2_ADDRESS1)
    await postman.flush()

    # Assert L1 withdrawal of deposited_amount fails.
    with pytest.raises(Exception, match="INVALID_MESSAGE_TO_CONSUME"):
        token_bridge_wrapper.withdraw(amount=deposited_amount, user=l1_recipient)

    # Perform two L1 withdrawals of each_withdrawal_amount and assert correct L1 balances.
    for i in range(1, 3):
        token_bridge_wrapper.withdraw(amount=each_withdrawal_amount, user=l1_recipient)
        assert (
            token_bridge_wrapper.get_bridge_balance()
            == deposited_amount - i * each_withdrawal_amount
        )
        assert token_bridge_wrapper.get_account_balance(l1_recipient) == (
            l1_recipient_initial_balance + i * each_withdrawal_amount
        )

    # Assert an additional L1 withdrawal will fail.
    with pytest.raises(Exception, match="INVALID_MESSAGE_TO_CONSUME"):
        token_bridge_wrapper.withdraw(amount=each_withdrawal_amount, user=l1_recipient)


@pytest.mark.parametrize("fee", [0, 1000], ids=["no_fee", "with_fee"])
@pytest.mark.parametrize("deposit_id_to_cancel", [0, 1])
@pytest.mark.asyncio
async def test_deposit_twice_cancel_and_reclaim_once(
    postman: Postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
    deposit_id_to_cancel: int,
    fee: int,
):
    """
    Deposit twice and randomly cancel and reclaim one of the deposits.
    """
    first_deposit_amount = AMOUNT
    second_deposit_amount = AMOUNT + 1
    cancelled_amount = first_deposit_amount if deposit_id_to_cancel == 0 else second_deposit_amount
    expected_bridge_amount = first_deposit_amount + second_deposit_amount - cancelled_amount

    await configure_bridge_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        l2_token_contract=l2_token_contract,
        l2_token_bridge_contract=l2_token_bridge_contract,
    )

    # Deposit twice to L2.
    l1_sender = token_bridge_wrapper.default_user
    l1_sender_initial_balance = token_bridge_wrapper.get_account_balance(l1_sender)
    assert l1_sender_initial_balance >= (
        first_deposit_amount
        + second_deposit_amount
        + token_bridge_wrapper.TRANSACTION_COSTS_BOUND * 2
    )
    token_bridge_wrapper.deposit(
        amount=first_deposit_amount, l2_recipient=L2_ADDRESS1, fee=fee, user=l1_sender
    )
    token_bridge_wrapper.deposit(
        amount=second_deposit_amount, l2_recipient=L2_ADDRESS1, fee=fee, user=l1_sender
    )

    # Assert recipient account's balance has been updated.
    assert token_bridge_wrapper.get_bridge_balance() == first_deposit_amount + second_deposit_amount

    # Cancel & reclaim deposit deposit_id_to_cancel and assert a deposit has been
    # canceled & reclaimed.
    token_bridge_wrapper.deposit_cancel_request(
        amount=cancelled_amount,
        l2_recipient=L2_ADDRESS1,
        nonce=deposit_id_to_cancel,
        user=l1_sender,
    )
    token_bridge_wrapper.deposit_reclaim(
        amount=cancelled_amount,
        l2_recipient=L2_ADDRESS1,
        nonce=deposit_id_to_cancel,
        user=l1_sender,
    )
    with pytest.raises(Exception, match="INVALID_MESSAGE_TO_CONSUME"):
        await postman.flush()

    # Assert the correct deposit (and only that deposit) has been canceled & reclaimed.
    assert token_bridge_wrapper.get_bridge_balance() == expected_bridge_amount
