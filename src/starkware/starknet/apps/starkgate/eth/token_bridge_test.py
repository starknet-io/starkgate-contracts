import pytest

from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME
from starkware.eth.eth_test_utils import EthContract, EthRevertException, EthTestUtils
from starkware.starknet.apps.starkgate.conftest import ERC20BridgeWrapper, TokenBridgeWrapper
from starkware.starknet.services.api.messages import StarknetMessageToL1, StarknetMessageToL2
from starkware.starknet.testing.contracts import MockStarknetMessaging

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
WITHDRAW = 0
SELECTOR = 1285101517810983806491589552491143496277809242732141897358598292095611420389
L2_TOKEN_CONTRACT = 42
L2_RECIPIENT = 37

INITIAL_BRIDGE_BALANCE = 7
DEPOSIT_AMOUNT = 6
WITHDRAW_AMOUNT = 3
MESSAGE_CANCEL_DELAY = 1000


@pytest.fixture
def mock_starknet_messaging_contract(eth_test_utils: EthTestUtils) -> EthContract:
    return eth_test_utils.accounts[0].deploy(MockStarknetMessaging, MESSAGE_CANCEL_DELAY)


def setup_contracts(
    token_bridge_wrapper: TokenBridgeWrapper,
    initial_bridge_balance: int = INITIAL_BRIDGE_BALANCE,
):
    """
    Setups balances and allowances for the bridge and for a given user. The default user is the
    default account.
    """
    token_bridge_wrapper.set_bridge_balance(initial_bridge_balance)
    token_bridge_wrapper.contract.setL2TokenBridge.transact(L2_TOKEN_CONTRACT)
    token_bridge_wrapper.contract.setMaxTotalBalance.transact(2**256 - 1)
    token_bridge_wrapper.contract.setMaxDeposit.transact(2**256 - 1)


def test_set_l2_token_contract_invalid_address(token_bridge_wrapper: TokenBridgeWrapper):
    with pytest.raises(EthRevertException, match="L2_ADDRESS_OUT_OF_RANGE"):
        token_bridge_wrapper.contract.setL2TokenBridge.call(0)
    with pytest.raises(EthRevertException, match="L2_ADDRESS_OUT_OF_RANGE"):
        token_bridge_wrapper.contract.setL2TokenBridge.call(DEFAULT_PRIME)


def test_set_l2_token_contract_replay(token_bridge_wrapper: TokenBridgeWrapper):
    default_user = token_bridge_wrapper.default_user
    token_bridge_wrapper.contract.setL2TokenBridge.transact(
        L2_TOKEN_CONTRACT, transact_args={"from": default_user}
    )
    with pytest.raises(EthRevertException, match="ALREADY_SET"):
        token_bridge_wrapper.contract.setL2TokenBridge.call(L2_TOKEN_CONTRACT)


def test_governance(token_bridge_wrapper: TokenBridgeWrapper):
    bridge_contract = token_bridge_wrapper.contract
    default_user = token_bridge_wrapper.default_user
    non_default_user = token_bridge_wrapper.non_default_user
    with pytest.raises(EthRevertException, match="ONLY_GOVERNANCE"):
        bridge_contract.setL2TokenBridge.call(
            L2_TOKEN_CONTRACT, transact_args={"from": non_default_user}
        )
    with pytest.raises(EthRevertException, match="ONLY_GOVERNANCE"):
        bridge_contract.setMaxTotalBalance.call(
            2**256 - 1, transact_args={"from": non_default_user}
        )
    with pytest.raises(EthRevertException, match="ONLY_GOVERNANCE"):
        bridge_contract.setMaxDeposit.call(2**256 - 1, transact_args={"from": non_default_user})

    bridge_contract.setL2TokenBridge.transact(
        L2_TOKEN_CONTRACT, transact_args={"from": default_user}
    )
    bridge_contract.setMaxTotalBalance.transact(2**256 - 1, transact_args={"from": default_user})
    bridge_contract.setMaxDeposit.transact(2**256 - 1, transact_args={"from": default_user})


def test_deposit_l2_token_contract_not_set(
    token_bridge_wrapper: TokenBridgeWrapper, eth_test_utils: EthTestUtils
):
    default_user = token_bridge_wrapper.default_user
    token_bridge_wrapper.contract.setMaxTotalBalance.transact(
        2**256 - 1, transact_args={"from": default_user}
    )
    token_bridge_wrapper.contract.setMaxDeposit.transact(
        2**256 - 1, transact_args={"from": default_user}
    )
    with pytest.raises(EthRevertException, match="L2_TOKEN_CONTRACT_NOT_SET"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_positive_flow(
    token_bridge_wrapper: TokenBridgeWrapper,
    mock_starknet_messaging_contract: EthContract,
):
    setup_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        # In the full flow, the bridge receives funds only from calls to deposit.
        initial_bridge_balance=0,
    )

    # We want to ignore costs from setup_contracts.
    initial_user_balance = token_bridge_wrapper.get_account_balance(
        token_bridge_wrapper.default_user
    )
    assert initial_user_balance >= DEPOSIT_AMOUNT + token_bridge_wrapper.TRANSACTION_COSTS_BOUND

    deposit_receipt = token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)
    total_costs = token_bridge_wrapper.get_tx_cost(deposit_receipt)

    assert token_bridge_wrapper.get_bridge_balance() == DEPOSIT_AMOUNT
    assert token_bridge_wrapper.get_account_balance(account=token_bridge_wrapper.default_user) == (
        initial_user_balance - DEPOSIT_AMOUNT - total_costs
    )

    tx_receipt = mock_starknet_messaging_contract.mockSendMessageFromL2.transact(
        L2_TOKEN_CONTRACT,
        int(token_bridge_wrapper.contract.address, 16),
        [
            WITHDRAW,
            int(token_bridge_wrapper.default_user.address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )
    total_costs += token_bridge_wrapper.get_tx_cost(tx_receipt)

    withdrawal_receipt = token_bridge_wrapper.withdraw(amount=WITHDRAW_AMOUNT)
    total_costs += token_bridge_wrapper.get_tx_cost(withdrawal_receipt)

    assert token_bridge_wrapper.get_bridge_balance() == (DEPOSIT_AMOUNT - WITHDRAW_AMOUNT)
    assert token_bridge_wrapper.get_account_balance(account=token_bridge_wrapper.default_user) == (
        initial_user_balance - DEPOSIT_AMOUNT + WITHDRAW_AMOUNT - total_costs
    )


def test_deposit_events(token_bridge_wrapper: TokenBridgeWrapper):
    deposit_filter = token_bridge_wrapper.contract.w3_contract.events.LogDeposit.createFilter(
        fromBlock="latest"
    )
    withdrawal_filter = token_bridge_wrapper.contract.w3_contract.events.LogWithdrawal.createFilter(
        fromBlock="latest"
    )
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)

    assert dict(deposit_filter.get_new_entries()[0].args) == dict(
        sender=token_bridge_wrapper.default_user.address,
        amount=DEPOSIT_AMOUNT,
        l2Recipient=L2_RECIPIENT,
    )
    assert len(withdrawal_filter.get_new_entries()) == 0


def test_withdraw_events(
    token_bridge_wrapper: TokenBridgeWrapper, mock_starknet_messaging_contract
):
    deposit_filter = token_bridge_wrapper.contract.w3_contract.events.LogDeposit.createFilter(
        fromBlock="latest"
    )
    withdrawal_filter = token_bridge_wrapper.contract.w3_contract.events.LogWithdrawal.createFilter(
        fromBlock="latest"
    )
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)

    mock_starknet_messaging_contract.mockSendMessageFromL2.transact(
        L2_TOKEN_CONTRACT,
        int(token_bridge_wrapper.contract.address, 16),
        [
            WITHDRAW,
            int(token_bridge_wrapper.default_user.address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )

    token_bridge_wrapper.withdraw(amount=WITHDRAW_AMOUNT)

    assert dict(withdrawal_filter.get_new_entries()[0].args) == dict(
        recipient=token_bridge_wrapper.default_user.address,
        amount=WITHDRAW_AMOUNT,
    )
    assert len(deposit_filter.get_new_entries()) == 0


def test_set_values_events(token_bridge_wrapper: TokenBridgeWrapper):
    w3_events = token_bridge_wrapper.contract.w3_contract.events
    l2_token_bridge_filter = w3_events.LogSetL2TokenBridge.createFilter(fromBlock="latest")
    max_total_balance_filter = w3_events.LogSetMaxTotalBalance.createFilter(fromBlock="latest")
    max_deposit_filter = w3_events.LogSetMaxDeposit.createFilter(fromBlock="latest")

    bridge_contract = token_bridge_wrapper.contract
    default_user = token_bridge_wrapper.default_user
    tx = bridge_contract.setL2TokenBridge.transact(
        L2_TOKEN_CONTRACT, transact_args={"from": default_user}
    )
    assert dict(l2_token_bridge_filter.get_new_entries()[0].args) == dict(value=L2_TOKEN_CONTRACT)
    tx = bridge_contract.setMaxTotalBalance.transact(1, transact_args={"from": default_user})
    assert dict(max_total_balance_filter.get_new_entries()[0].args) == dict(value=1)
    tx = bridge_contract.setMaxDeposit.transact(2, transact_args={"from": default_user})
    assert dict(max_deposit_filter.get_new_entries()[0].args) == dict(value=2)


def test_deposit_message_sent(
    token_bridge_wrapper: TokenBridgeWrapper, mock_starknet_messaging_contract
):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)

    l1_to_l2_msg = StarknetMessageToL2(
        from_address=int(token_bridge_wrapper.contract.address, 16),
        to_address=L2_TOKEN_CONTRACT,
        l1_handler_selector=SELECTOR,
        payload=[L2_RECIPIENT, DEPOSIT_AMOUNT % 2**128, DEPOSIT_AMOUNT // 2**128],
        nonce=0,
    )
    assert mock_starknet_messaging_contract.l1ToL2Messages.call(l1_to_l2_msg.get_hash()) == 1


def test_withdraw_message_consumed(
    token_bridge_wrapper: TokenBridgeWrapper,
    mock_starknet_messaging_contract,
    eth_test_utils: EthTestUtils,
):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    bridge_address = int(token_bridge_wrapper.contract.address, 16)
    l2_to_l1_msg = StarknetMessageToL1(
        from_address=L2_TOKEN_CONTRACT,
        to_address=bridge_address,
        payload=[
            WITHDRAW,
            int(token_bridge_wrapper.default_user.address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )

    assert mock_starknet_messaging_contract.l2ToL1Messages.call(l2_to_l1_msg.get_hash()) == 0
    mock_starknet_messaging_contract.mockSendMessageFromL2.transact(
        L2_TOKEN_CONTRACT,
        bridge_address,
        [
            WITHDRAW,
            int(eth_test_utils.accounts[0].address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )
    assert mock_starknet_messaging_contract.l2ToL1Messages.call(l2_to_l1_msg.get_hash()) == 1

    token_bridge_wrapper.withdraw(amount=WITHDRAW_AMOUNT)

    assert mock_starknet_messaging_contract.l2ToL1Messages.call(l2_to_l1_msg.get_hash()) == 0


def test_withdraw_from_another_address(
    token_bridge_wrapper: TokenBridgeWrapper,
    mock_starknet_messaging_contract,
):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)

    mock_starknet_messaging_contract.mockSendMessageFromL2.transact(
        L2_TOKEN_CONTRACT,
        int(token_bridge_wrapper.contract.address, 16),
        [
            WITHDRAW,
            int(token_bridge_wrapper.non_default_user.address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )

    initial_user_balance = token_bridge_wrapper.get_account_balance(
        token_bridge_wrapper.non_default_user
    )

    token_bridge_wrapper.withdraw(
        amount=WITHDRAW_AMOUNT, user=token_bridge_wrapper.non_default_user
    )

    assert token_bridge_wrapper.get_account_balance(token_bridge_wrapper.non_default_user) == (
        initial_user_balance + WITHDRAW_AMOUNT
    )
    assert token_bridge_wrapper.get_bridge_balance() == INITIAL_BRIDGE_BALANCE - WITHDRAW_AMOUNT


# We can't cause a situation where the global ETH supply is 2**256.
@pytest.mark.parametrize("token_bridge_wrapper", [ERC20BridgeWrapper], indirect=True)
def test_deposit_overflow(token_bridge_wrapper: TokenBridgeWrapper):
    token_bridge_wrapper.reset_balances()
    setup_contracts(
        token_bridge_wrapper=token_bridge_wrapper,
        initial_bridge_balance=2**256 - DEPOSIT_AMOUNT,
    )
    with pytest.raises(EthRevertException, match="OVERFLOW"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_withdraw_underflow(
    token_bridge_wrapper: TokenBridgeWrapper, mock_starknet_messaging_contract
):
    setup_contracts(
        token_bridge_wrapper=token_bridge_wrapper, initial_bridge_balance=WITHDRAW_AMOUNT - 1
    )
    mock_starknet_messaging_contract.mockSendMessageFromL2.transact(
        L2_TOKEN_CONTRACT,
        int(token_bridge_wrapper.contract.address, 16),
        [
            WITHDRAW,
            int(token_bridge_wrapper.default_user.address, 16),
            WITHDRAW_AMOUNT % 2**128,
            WITHDRAW_AMOUNT // 2**128,
        ],
    )
    with pytest.raises(EthRevertException) as _ex:
        token_bridge_wrapper.withdraw(amount=WITHDRAW_AMOUNT)
    assert any(msg in str(_ex.value) for msg in ["ETH_TRANSFER_FAILED", "UNDERFLOW"])


def test_withdraw_no_message(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    with pytest.raises(EthRevertException, match="INVALID_MESSAGE_TO_CONSUME"):
        token_bridge_wrapper.withdraw(amount=WITHDRAW_AMOUNT)


def test_deposit_invalid_l2_recipient(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    with pytest.raises(EthRevertException, match="L2_ADDRESS_OUT_OF_RANGE"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=0)
    with pytest.raises(EthRevertException, match="L2_ADDRESS_OUT_OF_RANGE"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=DEFAULT_PRIME)


def test_deposit_max_balance_almost_exceeded(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.contract.setMaxTotalBalance.transact(
        INITIAL_BRIDGE_BALANCE + DEPOSIT_AMOUNT,
        transact_args={"from": token_bridge_wrapper.default_user},
    )
    token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_deposit_max_balance_exceeded(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.contract.setMaxTotalBalance.transact(
        INITIAL_BRIDGE_BALANCE + DEPOSIT_AMOUNT - 1,
        transact_args={"from": token_bridge_wrapper.default_user},
    )
    with pytest.raises(EthRevertException, match="MAX_BALANCE_EXCEEDED"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_deposit_amount_almost_exceeded(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.contract.setMaxDeposit.transact(
        DEPOSIT_AMOUNT, transact_args={"from": token_bridge_wrapper.default_user}
    )
    token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_deposit_amount_exceeded(token_bridge_wrapper: TokenBridgeWrapper):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper)
    token_bridge_wrapper.contract.setMaxDeposit.transact(
        DEPOSIT_AMOUNT - 1, transact_args={"from": token_bridge_wrapper.default_user}
    )
    with pytest.raises(EthRevertException, match="TRANSFER_TO_STARKNET_AMOUNT_EXCEEDED"):
        token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)


def test_hacked_cancel_deposit(
    eth_test_utils: EthTestUtils,
    token_bridge_wrapper: TokenBridgeWrapper,
    mock_starknet_messaging_contract: EthContract,
):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper, initial_bridge_balance=0)

    # Make a deposit on the bridge.
    tx_receipt = token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)
    assert token_bridge_wrapper.get_bridge_balance() == DEPOSIT_AMOUNT

    # Initiate deposit cancellation from non-depositor.
    with pytest.raises(EthRevertException, match="ONLY_DEPOSITOR"):
        tx_receipt = token_bridge_wrapper.deposit_cancel_request(
            amount=DEPOSIT_AMOUNT,
            l2_recipient=L2_RECIPIENT,
            nonce=0,
            user=token_bridge_wrapper.non_default_user,
        )

    # Initiate deposit cancellation from depositor (so we can get to second stage...).
    token_bridge_wrapper.deposit_cancel_request(
        amount=DEPOSIT_AMOUNT,
        l2_recipient=L2_RECIPIENT,
        nonce=0,
    )

    # Wait for time-lock to expire.
    eth_test_utils.advance_time(MESSAGE_CANCEL_DELAY)

    # Only depositor can claim the funds.
    with pytest.raises(EthRevertException, match="ONLY_DEPOSITOR"):
        token_bridge_wrapper.deposit_reclaim(
            amount=DEPOSIT_AMOUNT,
            l2_recipient=L2_RECIPIENT,
            nonce=0,
            user=token_bridge_wrapper.non_default_user,
        )

    # Complete the cancellation successfully.
    token_bridge_wrapper.deposit_reclaim(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT, nonce=0)
    assert token_bridge_wrapper.get_bridge_balance() == 0


def test_cancel_deposit(
    eth_test_utils: EthTestUtils,
    token_bridge_wrapper: TokenBridgeWrapper,
    mock_starknet_messaging_contract: EthContract,
):
    setup_contracts(token_bridge_wrapper=token_bridge_wrapper, initial_bridge_balance=0)
    bridge = token_bridge_wrapper.contract

    # Make a deposit on the bridge.
    tx_receipt = token_bridge_wrapper.deposit(amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT)
    _sender = tx_receipt.w3_tx_receipt["from"]
    assert token_bridge_wrapper.get_bridge_balance() == DEPOSIT_AMOUNT
    with pytest.raises(EthRevertException, match="NO_DEPOSIT_TO_CANCEL"):
        token_bridge_wrapper.deposit_cancel_request(
            amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT, nonce=1
        )

    # Initiate deposit cancellation.
    tx_receipt = token_bridge_wrapper.deposit_cancel_request(
        amount=DEPOSIT_AMOUNT,
        l2_recipient=L2_RECIPIENT,
        nonce=0,
    )

    deposit_cancel_event = bridge.get_events(tx=tx_receipt, name="LogDepositCancelRequest")[-1]
    msg_cancel_req_ev = mock_starknet_messaging_contract.get_events(
        tx=tx_receipt,
        name="MessageToL2CancellationStarted",
    )[-1]

    assert deposit_cancel_event == {
        "sender": _sender,
        "amount": DEPOSIT_AMOUNT,
        "l2Recipient": L2_RECIPIENT,
        "nonce": 0,
    }

    assert msg_cancel_req_ev == {
        "fromAddress": bridge.address,
        "toAddress": L2_TOKEN_CONTRACT,
        "selector": SELECTOR,
        "payload": [L2_RECIPIENT, DEPOSIT_AMOUNT, 0],
        "nonce": 0,
    }

    # Try to reclaim deposit with different properties (not existing deposit or not cancelled one).
    with pytest.raises(EthRevertException, match="NO_DEPOSIT_TO_CANCEL"):
        token_bridge_wrapper.deposit_reclaim(
            amount=DEPOSIT_AMOUNT,
            l2_recipient=L2_RECIPIENT,
            nonce=1,  # Bad nonce.
        )

    # Try to reclaim the right deposit but too early.
    with pytest.raises(EthRevertException, match="MESSAGE_CANCELLATION_NOT_ALLOWED_YET"):
        token_bridge_wrapper.deposit_reclaim(
            amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT, nonce=0
        )

    # Reclaim the deposit successfully.
    eth_test_utils.advance_time(MESSAGE_CANCEL_DELAY)
    tx_receipt = token_bridge_wrapper.deposit_reclaim(
        amount=DEPOSIT_AMOUNT,
        l2_recipient=L2_RECIPIENT,
        nonce=0,
    )

    reclaim_event = bridge.get_events(tx=tx_receipt, name="LogDepositReclaimed")[-1]
    msg_cancel_ev = mock_starknet_messaging_contract.get_events(
        tx=tx_receipt, name="MessageToL2Canceled"
    )[-1]

    assert reclaim_event == {
        "sender": _sender,
        "amount": DEPOSIT_AMOUNT,
        "l2Recipient": L2_RECIPIENT,
        "nonce": 0,
    }

    assert msg_cancel_ev == {
        "fromAddress": bridge.address,
        "toAddress": L2_TOKEN_CONTRACT,
        "selector": SELECTOR,
        "payload": [L2_RECIPIENT, DEPOSIT_AMOUNT, 0],
        "nonce": 0,
    }

    assert token_bridge_wrapper.get_bridge_balance() == 0

    # Try and fail to reclaim the deposit a second time.
    with pytest.raises(EthRevertException, match="NO_MESSAGE_TO_CANCEL"):
        token_bridge_wrapper.deposit_reclaim(
            amount=DEPOSIT_AMOUNT, l2_recipient=L2_RECIPIENT, nonce=0
        )
