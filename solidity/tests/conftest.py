from abc import ABC, abstractmethod
from typing import Iterator, List, Optional

import pytest

from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME
from starkware.eth.eth_test_utils import EthAccount, EthContract, EthReceipt, EthTestUtils
from starkware.solidity.test_contracts.contracts import TestERC20
from starkware.solidity.upgrade.contracts import Proxy
from starkware.starknet.apps.starkgate.eth.contracts import StarknetERC20Bridge
from starkware.starknet.apps.starkgate.eth.test_contracts import StarknetEthBridgeTester
from starkware.starknet.solidity.starknet_test_utils import (
    UPGRADE_DELAY,
    add_implementation_and_upgrade,
)


def str_to_felt(short_text: str) -> int:
    felt = int.from_bytes(bytes(short_text, encoding="ascii"), "big")
    assert felt < DEFAULT_PRIME, f"{short_text} is too long"
    return felt


@pytest.fixture(scope="session")
def token_decimals() -> int:
    return 6


@pytest.fixture(scope="session")
def token_symbol() -> int:
    return str_to_felt("TKN")


@pytest.fixture(scope="session")
def token_name() -> int:
    return str_to_felt("TOKEN")


ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


def chain_hexes_to_bytes(hexes: List[str]) -> bytes:
    """
    Chain arguments to one big endian bytes array.
    Support address (or other HexStr that fit in 256 bits), bytes and int (as 256 bits integer).
    """
    result = bytes()
    for num in hexes:
        result += int(num, 16).to_bytes(32, "big")
    return result


def wrap_contract(contract: EthContract, wrapper_address: str) -> EthContract:
    return EthContract(
        w3=contract.w3,
        address=wrapper_address,
        w3_contract=contract.w3.eth.contract(  # type: ignore
            address=wrapper_address, abi=contract.abi
        ),
        abi=contract.abi,
        deployer=contract.deployer,
    )


@pytest.fixture(scope="session")
def eth_test_utils() -> Iterator[EthTestUtils]:
    with EthTestUtils.context_manager() as val:
        yield val


class TokenBridgeWrapper(ABC):
    """
    Wraps a StarknetTokenBridge so that all deriving contracts of it can be called with the same
    API. Also allows APIs for setting and getting balances. Allows abstraction of the token that
    this bridge represents (ERC20 or ETH)
    """

    # A bound that any transaction's cost will be lower than.
    TRANSACTION_COSTS_BOUND: int

    def __init__(
        self,
        compiled_bridge_contract: dict,
        eth_test_utils: EthTestUtils,
        init_data: bytes,
    ):
        self.default_user = eth_test_utils.accounts[0]
        self.non_default_user = eth_test_utils.accounts[1]
        self.contract = self.default_user.deploy(compiled_bridge_contract)
        proxy = self.default_user.deploy(Proxy, UPGRADE_DELAY)

        add_implementation_and_upgrade(
            proxy=proxy,
            new_impl=self.contract.address,
            init_data=init_data,
            governor=self.default_user,
        )
        self.contract = wrap_contract(contract=self.contract, wrapper_address=proxy.address)

    @abstractmethod
    def deposit(
        self, amount: int, l2_recipient: int, user: Optional[EthAccount] = None
    ) -> EthReceipt:
        """
        Deposit tokens into the bridge. If user isn't specified, the default user will be used.
        """

    def withdraw(self, amount: int, user: Optional[EthAccount] = None) -> EthReceipt:
        """
        Withdraw tokens from the bridge. If user isn't specified, the default user will be used.
        """
        if user is None:
            return self.contract.withdraw.transact(
                amount, transact_args={"from": self.default_user}
            )
        else:
            return self.contract.withdraw.transact(
                amount, user, transact_args={"from": self.default_user}
            )

    def deposit_cancel_request(
        self, amount: int, l2_recipient: int, nonce: int, user: Optional[EthAccount] = None
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        return self.contract.depositCancelRequest.transact(
            amount, l2_recipient, nonce, transact_args={"from": user}
        )

    def deposit_reclaim(
        self, amount: int, l2_recipient: int, nonce: int, user: Optional[EthAccount] = None
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        return self.contract.depositReclaim.transact(
            amount, l2_recipient, nonce, transact_args={"from": user}
        )

    @abstractmethod
    def get_account_balance(self, account: EthAccount) -> int:
        pass

    @abstractmethod
    def get_bridge_balance(self) -> int:
        pass

    @abstractmethod
    def set_bridge_balance(self, amount: int):
        pass

    @abstractmethod
    def get_tx_cost(self, tx_receipt: EthReceipt) -> int:
        """
        Get the amount of tokens executing a transaction will cost (for example, from gas).
        """


class ERC20BridgeWrapper(TokenBridgeWrapper):
    TRANSACTION_COSTS_BOUND: int = 0

    def __init__(
        self,
        mock_starknet_messaging_contract: EthContract,
        eth_test_utils: EthTestUtils,
    ):
        self.mock_erc20_contract = eth_test_utils.accounts[0].deploy(TestERC20)

        super().__init__(
            compiled_bridge_contract=StarknetERC20Bridge,
            eth_test_utils=eth_test_utils,
            init_data=chain_hexes_to_bytes(
                [
                    ZERO_ADDRESS,
                    self.mock_erc20_contract.address,
                    mock_starknet_messaging_contract.address,
                ]
            ),
        )

        INITIAL_BALANCE = 10**20
        for account in (self.default_user, self.non_default_user):
            self.set_account_balance(account=account, amount=INITIAL_BALANCE)

    def deposit(
        self, amount: int, l2_recipient: int, user: Optional[EthAccount] = None
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        self.mock_erc20_contract.approve.transact(
            self.contract.address, amount, transact_args={"from": user}
        )
        return self.contract.deposit.transact(amount, l2_recipient, transact_args={"from": user})

    def get_account_balance(self, account: EthAccount) -> int:
        return self.mock_erc20_contract.balanceOf.call(account.address)

    def get_bridge_balance(self) -> int:
        return self.mock_erc20_contract.balanceOf.call(self.contract.address)

    def set_account_balance(self, account: EthAccount, amount: int):
        self.mock_erc20_contract.setBalance.transact(account.address, amount)

    def set_bridge_balance(self, amount: int):
        self.mock_erc20_contract.setBalance.transact(self.contract.address, amount)

    def get_tx_cost(self, tx_receipt: EthReceipt) -> int:
        return 0

    def reset_balances(self):
        self.set_bridge_balance(amount=0)
        for account in (self.default_user, self.non_default_user):
            self.set_account_balance(account=account, amount=0)


class EthBridgeWrapper(TokenBridgeWrapper):
    # The bound is worth around 480Gwei * 21000.
    TRANSACTION_COSTS_BOUND: int = 10**16

    def __init__(
        self,
        mock_starknet_messaging_contract: EthContract,
        eth_test_utils: EthTestUtils,
    ):
        super().__init__(
            compiled_bridge_contract=StarknetEthBridgeTester,
            eth_test_utils=eth_test_utils,
            init_data=chain_hexes_to_bytes(
                [ZERO_ADDRESS, ZERO_ADDRESS, mock_starknet_messaging_contract.address]
            ),
        )
        self.patron = eth_test_utils.accounts[-1]
        assert self.patron != self.default_user
        assert self.patron != self.non_default_user

    def deposit(
        self, amount: int, l2_recipient: int, user: Optional[EthAccount] = None
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        return self.contract.deposit.transact(
            l2_recipient, transact_args={"value": amount, "from": user}
        )

    def get_account_balance(self, account: EthAccount) -> int:
        return account.balance

    def get_bridge_balance(self) -> int:
        return self.contract.balance

    def set_bridge_balance(self, amount: int):
        """
        Uses the test contract functionality in order to change the bridge's eth balance.
        """
        curr_balance = self.get_bridge_balance()
        if amount > curr_balance:
            self.contract.receiveEth.transact(
                transact_args={"from": self.patron, "value": amount - curr_balance}
            )
        else:
            self.contract.sendEth.transact(
                curr_balance - amount, transact_args={"from": self.patron}
            )

    def get_tx_cost(self, tx_receipt: EthReceipt) -> int:
        return tx_receipt.get_cost()


@pytest.fixture(params=[ERC20BridgeWrapper, EthBridgeWrapper])
def token_bridge_wrapper(
    request, mock_starknet_messaging_contract: EthContract, eth_test_utils: EthTestUtils
) -> TokenBridgeWrapper:
    return request.param(
        mock_starknet_messaging_contract=mock_starknet_messaging_contract,
        eth_test_utils=eth_test_utils,
    )
