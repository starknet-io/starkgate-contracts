import asyncio
from abc import ABC, abstractmethod
from typing import Iterator, List, Optional, Type

import pytest
import pytest_asyncio
from solidity.utils import load_contract, str_to_felt
from starkware.starknet.business_logic.state.state_api_objects import BlockInfo

from starkware.eth.eth_test_utils import (
    EthAccount,
    EthContract,
    EthReceipt,
    EthTestUtils,
)

from starkware.starknet.testing.starknet import Starknet

from solidity.contracts import StarknetTokenBridge, starkgate_registry, starkgate_manager
from solidity.test_contracts import StarknetEthBridgeTester

UPGRADE_DELAY = 0
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop()
    yield loop
    loop.close()


TestERC20 = load_contract("TestERC20")
Proxy = load_contract("Proxy")


def advance_time(starknet: Starknet, block_time_diff: int, block_num_diff: int = 1):
    """
    Advances timestamp/blocknum on the starknet object.
    """
    assert block_time_diff > 0, f"block_timestamp diff {block_time_diff} too low"
    assert block_num_diff > 0, f"block_number diff {block_num_diff} too low"

    _block_info = starknet.state.state.block_info
    _current_time = _block_info.block_timestamp
    _current_block = _block_info.block_number

    new_block_timestamp = _current_time + block_time_diff
    new_block_number = _current_block + block_num_diff

    new_block_info = BlockInfo.create_for_testing(
        block_number=new_block_number, block_timestamp=new_block_timestamp
    )
    starknet.state.state.block_info = new_block_info


@pytest_asyncio.fixture(scope="session")
async def session_starknet() -> Starknet:
    starknet = await Starknet.empty()
    # We want to start with a non-zero block/time (this would fail tests).
    advance_time(starknet=starknet, block_time_diff=1, block_num_diff=1)
    return starknet


def deploy_proxy(governor: EthContract) -> EthContract:
    proxy = governor.deploy(Proxy, UPGRADE_DELAY)
    proxy.registerUpgradeGovernor(governor.address)
    return proxy


def add_implementation_and_upgrade(proxy, new_impl, init_data, governor, is_finalizing=False):
    proxy.addImplementation.transact(
        new_impl, init_data, is_finalizing, transact_args={"from": governor}
    )
    return proxy.upgradeTo.transact(
        new_impl, init_data, is_finalizing, transact_args={"from": governor}
    )


@pytest_asyncio.fixture(scope="session")
async def l2_governor_address(session_starknet: Starknet) -> int:
    # Declare and deploy an unlocked mock account and return its address.
    return await session_starknet.deploy_simple_account()


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
def max_total_balance_amount() -> int:
    return (2**256) - 1


@pytest.fixture(scope="session")
def max_deposit_amount() -> int:
    return (2**256) - 1


def chain_hexes_to_bytes(hexes: List[str]) -> bytes:
    """
    Chain arguments to one big endian bytes array.
    Support address (or other HexStr that fit in 256 bits), bytes and int (as 256 bits integer).
    """
    result = bytes()
    for num in hexes:
        result += int(num, 16).to_bytes(32, "big")
    return result


@pytest.fixture(scope="session")
def eth_test_utils() -> Iterator[EthTestUtils]:
    with EthTestUtils.context_manager() as val:
        yield val


@pytest.fixture(scope="session")
def governor(eth_test_utils: EthTestUtils) -> EthContract:
    return eth_test_utils.accounts[0]


@pytest.fixture
def registry_proxy(governor: EthContract) -> EthContract:
    return deploy_proxy(governor=governor)


@pytest.fixture
def manager_proxy(governor: EthContract, registry_proxy: EthContract) -> EthContract:
    assert registry_proxy  # Order enforcement.
    return deploy_proxy(governor=governor)


@pytest.fixture
def bridge_proxy(governor: EthContract, manager_proxy: EthContract) -> EthContract:
    assert manager_proxy  # Order enforcement.
    return deploy_proxy(governor=governor)


@pytest.fixture
def registry_contract(
    governor: EthContract, registry_proxy: EthContract, manager_proxy: EthContract
) -> EthContract:
    starkgate_registry_impl = governor.deploy(starkgate_registry)
    init_data = chain_hexes_to_bytes([ZERO_ADDRESS, manager_proxy.address])
    add_implementation_and_upgrade(
        proxy=registry_proxy,
        new_impl=starkgate_registry_impl.address,
        init_data=init_data,
        governor=governor,
    )
    return registry_proxy.replace_abi(abi=starkgate_registry_impl.abi)


@pytest.fixture
def manager_contract(
    governor: EthContract,
    registry_proxy: EthContract,
    manager_proxy: EthContract,
    bridge_proxy: EthContract,
) -> EthContract:
    starkgate_manager_impl = governor.deploy(starkgate_manager)
    init_data = chain_hexes_to_bytes([ZERO_ADDRESS, registry_proxy.address, bridge_proxy.address])
    add_implementation_and_upgrade(
        proxy=manager_proxy,
        new_impl=starkgate_manager_impl.address,
        init_data=init_data,
        governor=governor,
    )
    return manager_proxy.replace_abi(abi=starkgate_manager_impl.abi)


@pytest.fixture
def app_role_admin(
    eth_test_utils: EthTestUtils, governor: EthContract, manager_contract: EthContract
) -> EthContract:
    manager_contract.registerAppRoleAdmin(
        eth_test_utils.accounts[1].address, transact_args={"from": governor}
    )
    return eth_test_utils.accounts[1]


@pytest.fixture
def token_admin(
    eth_test_utils: EthTestUtils, app_role_admin: EthContract, manager_contract: EthContract
) -> EthContract:
    manager_contract.registerTokenAdmin(
        eth_test_utils.accounts[2].address, transact_args={"from": app_role_admin}
    )
    return eth_test_utils.accounts[2]


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
        proxy.registerUpgradeGovernor(self.default_user.address)

        add_implementation_and_upgrade(
            proxy=proxy,
            new_impl=self.contract.address,
            init_data=init_data,
            governor=self.default_user,
        )
        self.contract = proxy.replace_abi(abi=self.contract.abi)

    @abstractmethod
    def deposit(
        self,
        amount: int,
        l2_recipient: int,
        fee: int,
        user: Optional[EthAccount] = None,
        message: Optional[list[int]] = None,
    ) -> EthReceipt:
        """
        Deposit tokens into the bridge. If user isn't specified, the default user will be used.
        """

    @abstractmethod
    def token_address(self) -> str:
        pass

    def withdraw(self, amount: int, user: Optional[EthAccount] = None) -> EthReceipt:
        """
        Withdraw tokens from the bridge. If user isn't specified, the default user will be used.
        """
        if user is None:
            return self.contract.withdraw.transact(
                self.token_address(), amount, transact_args={"from": self.default_user}
            )
        else:
            return self.contract.withdraw.transact(
                self.token_address(), amount, user, transact_args={"from": self.default_user}
            )

    def get_deposit_fee(self, receipt: EthReceipt) -> int:
        logs = self.contract.w3_contract.events.Deposit().processReceipt(
            receipt.w3_tx_receipt
        ) + self.contract.w3_contract.events.DepositWithMessage().processReceipt(
            receipt.w3_tx_receipt
        )

        return 0 if len(logs) == 0 else logs[0].args.fee

    def deposit_cancel_request(
        self,
        amount: int,
        l2_recipient: int,
        nonce: int,
        user: Optional[EthAccount] = None,
        message: Optional[list[int]] = None,
    ) -> EthReceipt:
        if user is None:
            user = self.default_user

        if message is None:
            return self.contract.depositCancelRequest(
                self.token_address(), amount, l2_recipient, nonce, transact_args={"from": user}
            )
        else:
            return self.contract.depositWithMessageCancelRequest(
                self.token_address(),
                amount,
                l2_recipient,
                message,
                nonce,
                transact_args={"from": user},
            )

    def deposit_reclaim(
        self,
        amount: int,
        l2_recipient: int,
        nonce: int,
        user: Optional[EthAccount] = None,
        message: Optional[list[int]] = None,
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        if message is None:
            return self.contract.depositReclaim(
                self.token_address(), amount, l2_recipient, nonce, transact_args={"from": user}
            )
        else:
            return self.contract.depositWithMessageReclaim(
                self.token_address(),
                amount,
                l2_recipient,
                message,
                nonce,
                transact_args={"from": user},
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
        registry_contract: EthContract,
        eth_test_utils: EthTestUtils,
    ):
        self.mock_erc20_contract = eth_test_utils.accounts[0].deploy(TestERC20)

        super().__init__(
            compiled_bridge_contract=StarknetTokenBridge,
            eth_test_utils=eth_test_utils,
            init_data=chain_hexes_to_bytes(
                [
                    ZERO_ADDRESS,
                    registry_contract.address,
                    mock_starknet_messaging_contract.address,
                ]
            ),
        )

        INITIAL_BALANCE = 10**20
        for account in (self.default_user, self.non_default_user):
            self.set_account_balance(account=account, amount=INITIAL_BALANCE)

    def token_address(self) -> str:
        return self.mock_erc20_contract.address

    def deposit(
        self,
        amount: int,
        l2_recipient: int,
        fee: int = 0,
        user: Optional[EthAccount] = None,
        message: Optional[list[int]] = None,
    ) -> EthReceipt:
        if user is None:
            user = self.default_user
        self.mock_erc20_contract.approve.transact(
            self.contract.address, amount, transact_args={"from": user}
        )
        if message is None:
            return self.contract.deposit(
                self.token_address(),
                amount,
                l2_recipient,
                transact_args={"from": user, "value": fee},
            )
        else:
            return self.contract.depositWithMessage(
                self.token_address(),
                amount,
                l2_recipient,
                message,
                transact_args={"from": user, "value": fee},
            )

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
        registry_contract: EthContract,
        eth_test_utils: EthTestUtils,
    ):
        super().__init__(
            compiled_bridge_contract=StarknetEthBridgeTester,
            eth_test_utils=eth_test_utils,
            init_data=chain_hexes_to_bytes(
                [ZERO_ADDRESS, registry_contract.address, mock_starknet_messaging_contract.address]
            ),
        )
        self.eth_test_utils = eth_test_utils

    def token_address(self) -> str:
        return ZERO_ADDRESS

    def deposit(
        self,
        amount: int,
        l2_recipient: int,
        fee: int = 0,
        user: Optional[EthAccount] = None,
        message: Optional[list[int]] = None,
    ) -> EthReceipt:
        if user is None:
            user = self.default_user

        if message is None:
            return self.contract.deposit(
                self.token_address(),
                amount,
                l2_recipient,
                transact_args={"from": user, "value": amount + fee},
            )
        else:
            return self.contract.depositWithMessage.transact(
                self.token_address(),
                amount,
                l2_recipient,
                message,
                transact_args={"from": user, "value": amount + fee},
            )

    def get_account_balance(self, account: EthAccount) -> int:
        return account.balance

    def get_bridge_balance(self) -> int:
        return self.contract.balance

    def set_bridge_balance(self, amount: int):
        self.eth_test_utils.set_account_balance(self.contract.address, amount)

    def get_tx_cost(self, tx_receipt: EthReceipt) -> int:
        return tx_receipt.get_cost() + self.get_deposit_fee(tx_receipt)


@pytest.fixture(params=[ERC20BridgeWrapper, EthBridgeWrapper], scope="session")
def token_type(request) -> Type[TokenBridgeWrapper]:
    return request.param


@pytest.fixture(scope="session")
def fee() -> int:
    return 1000
