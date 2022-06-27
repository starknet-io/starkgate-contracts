import pytest

from starkware.eth.eth_test_utils import EthContract, EthTestUtils
from starkware.starknet.apps.starkgate.cairo.contracts import bridge_contract_class
from starkware.starknet.apps.starkgate.conftest import TokenBridgeWrapper
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


@pytest.fixture
async def postman(eth_test_utils: EthTestUtils) -> Postman:
    postmen = await Postman.create(eth_test_utils=eth_test_utils)
    # We need to  advance the clock. Proxy relies on timestamp be gt 0.
    advance_time(starknet=postmen.starknet, block_time_diff=1, block_num_diff=1)
    return postmen


# This fixture is needed for the `token_bridge_wrapper` fixture.
@pytest.fixture
def mock_starknet_messaging_contract(postman) -> EthContract:
    return postman.mock_starknet_messaging_contract


@pytest.fixture
async def l2_token_contract(
    postman, token_name, token_symbol, token_decimals, l2_token_bridge_contract
) -> StarknetContract:
    starknet = postman.starknet
    token_proxy = await starknet.deploy(
        constructor_calldata=[UPGRADE_DELAY], contract_class=proxy_contract_class
    )
    await token_proxy.init_governance().invoke(caller_address=L2_GOVERNANCE_ADDRESS)

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
    await token_proxy.add_implementation(*proxy_func_params).invoke(
        caller_address=L2_GOVERNANCE_ADDRESS
    )
    await token_proxy.upgrade_to(*proxy_func_params).invoke(caller_address=L2_GOVERNANCE_ADDRESS)
    return token_proxy.replace_abi(impl_contract_abi=declared_token_impl.abi)


@pytest.fixture
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
    await proxy_impl.init_governance().invoke(caller_address=L2_GOVERNANCE_ADDRESS)

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
    await proxy_impl.add_implementation(*proxy_func_params).invoke(
        caller_address=L2_GOVERNANCE_ADDRESS
    )
    await proxy_impl.upgrade_to(*proxy_func_params).invoke(caller_address=L2_GOVERNANCE_ADDRESS)

    # Create a contract object of the bridge abi, and proxy's address & state.
    return proxy_impl.replace_abi(impl_contract_abi=declared_bridge_impl.abi)


async def configure_bridge_contracts(
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
):

    l1_token_bridge_contract = token_bridge_wrapper.contract

    # Connect between contracts.
    l1_token_bridge_contract.setL2TokenBridge.transact(
        l2_token_bridge_contract.contract_address,
        transact_args={"from": token_bridge_wrapper.default_user},
    )
    await l2_token_bridge_contract.set_l1_bridge(
        l1_bridge_address=int(l1_token_bridge_contract.address, 16)
    ).invoke(caller_address=L2_GOVERNANCE_ADDRESS)
    await l2_token_bridge_contract.set_l2_token(
        l2_token_address=l2_token_contract.contract_address
    ).invoke(caller_address=L2_GOVERNANCE_ADDRESS)

    # Setup caps.
    l1_token_bridge_contract.setMaxTotalBalance.transact(
        (2**256) - 1, transact_args={"from": token_bridge_wrapper.default_user}
    )
    l1_token_bridge_contract.setMaxDeposit.transact(
        (2**256) - 1, transact_args={"from": token_bridge_wrapper.default_user}
    )


@pytest.mark.asyncio
async def test_token_positive_flow(
    postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
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

    tx_receipt = token_bridge_wrapper.deposit(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, user=l1_sender
    )

    assert token_bridge_wrapper.get_account_balance(l1_sender) == (
        l1_sender_initial_balance - AMOUNT - token_bridge_wrapper.get_tx_cost(tx_receipt)
    )
    assert token_bridge_wrapper.get_bridge_balance() == AMOUNT

    await postman.flush()

    # Check the result.
    execution_info = await l2_token_contract.balanceOf(account=L2_ADDRESS1).invoke()
    assert execution_info.result == (
        l2_token_contract.Uint256(low=AMOUNT % (2**128), high=AMOUNT // (2**128)),
    )

    # Perform a transfer inside L2.
    uint256_amount = l2_token_contract.Uint256(low=AMOUNT % (2**128), high=AMOUNT // (2**128))
    await l2_token_contract.transfer(recipient=L2_ADDRESS2, amount=uint256_amount).invoke(
        caller_address=L2_ADDRESS1
    )

    l1_recipient = token_bridge_wrapper.non_default_user
    l1_recipient_initial_balance = token_bridge_wrapper.get_account_balance(l1_recipient)

    # Withdraw AMOUNT to L1.
    await l2_token_bridge_contract.initiate_withdraw(
        l1_recipient=int(l1_recipient.address, 16), amount=uint256_amount
    ).invoke(caller_address=L2_ADDRESS2)
    await postman.flush()
    token_bridge_wrapper.withdraw(amount=AMOUNT, user=l1_recipient)

    # Assert balances.
    assert token_bridge_wrapper.get_account_balance(l1_recipient) == (
        l1_recipient_initial_balance + AMOUNT
    )
    assert token_bridge_wrapper.get_bridge_balance() == 0


@pytest.mark.asyncio
async def test_deposit_cancel_reclaim(
    postman,
    token_bridge_wrapper: TokenBridgeWrapper,
    l2_token_contract: StarknetContract,
    l2_token_bridge_contract: StarknetContract,
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

    tx_receipt = token_bridge_wrapper.deposit(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, user=l1_sender
    )

    assert token_bridge_wrapper.get_bridge_balance() == AMOUNT

    token_bridge_wrapper.deposit_cancel_request(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, nonce=0, user=l1_sender
    )
    token_bridge_wrapper.deposit_reclaim(
        amount=AMOUNT, l2_recipient=L2_ADDRESS1, nonce=0, user=l1_sender
    )

    with pytest.raises(Exception, match="INVALID_MESSAGE_TO_CONSUME"):
        await postman.flush()
