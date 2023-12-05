import pytest
from web3 import Web3
from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME
from starkware.eth.eth_test_utils import EthContract, EthRevertException, EthTestUtils, EthAccount
from solidity.conftest import (
    add_implementation_and_upgrade,
    chain_hexes_to_bytes,
    deploy_legacy_erc20_bridge,
    deploy_legacy_eth_bridge,
    deploy_legacy_proxy,
    deploy_proxy,
    messaging_contract,
    mock_erc20_contract,
    StarknetTokenBridgeWrapper,
    EthBridgeWrapper,
    StarknetERC20BridgeWrapper,
    TokenBridgeWrapper,
    L1_TOKEN_ADDRESS_OF_ETH,
    L2_TOKEN_CONTRACT,
    MAX_UINT,
    HANDLE_TOKEN_DEPOSIT_SELECTOR,
    HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
    HANDLE_TOKEN_DEPLOYMENT_SELECTOR,
    TOKEN_ADDRESS,
    UpgradeAssistEIC,
    StarknetTokenBridge,
    StarknetEthBridge,
    StarknetERC20Bridge,
)
from solidity.utils import load_contract, load_legacy_contract
from starkware.starknet.services.api.messages import (
    StarknetMessageToL1,
    StarknetMessageToL2,
)
from starkware.starknet.testing.contracts import MockStarknetMessaging
from starkware.starknet.public.abi import get_selector_from_name

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
WITHDRAW = 0


L2_RECIPIENT = 37
MESSAGE = [500, 700, 1200]

INITIAL_BRIDGE_BALANCE = 7
HALF_DEPOSIT_AMOUNT = 3
DEPOSIT_AMOUNT = 2 * HALF_DEPOSIT_AMOUNT
WITHDRAW_AMOUNT = 3
MESSAGE_CANCEL_DELAY = 1000
MAX_TVL = 496351


@pytest.fixture(scope="session")
def multi_bridge_impl(governor: EthAccount) -> EthContract:
    return governor.deploy(StarknetTokenBridge)


@pytest.fixture(scope="session")
def compatible_eth_bridge_impl(governor: EthAccount) -> EthContract:
    return governor.deploy(StarknetEthBridge)


@pytest.fixture(scope="session")
def compatible_erc20_bridge_impl(governor: EthAccount) -> EthContract:
    return governor.deploy(StarknetERC20Bridge)


@pytest.fixture(scope="session")
def legacy_erc20_bridge_impl(governor: EthAccount) -> EthContract:
    return deploy_legacy_erc20_bridge(governor=governor)


@pytest.fixture(scope="session")
def legacy_eth_bridge_impl(governor: EthAccount) -> EthContract:
    return deploy_legacy_eth_bridge(governor=governor)


@pytest.fixture(scope="session")
def upgrade_eic(governor: EthAccount) -> EthContract:
    return governor.deploy(UpgradeAssistEIC)


@pytest.fixture
def legacy_tester_eth_bridge(
    governor: EthAccount, legacy_eth_bridge_impl: EthContract, messaging_contract: EthContract
) -> EthContract:
    proxy = deploy_legacy_proxy(governor=governor)
    return setup_bridge(governor, proxy, legacy_eth_bridge_impl, ZERO_ADDRESS, messaging_contract)


def setup_bridge(
    governor: EthAccount,
    proxy: EthContract,
    bridge_impl: EthContract,
    l1_token: EthAccount,
    messaging_contract: EthContract,
) -> EthContract:
    l2_bridge_fake_address = 0x12345678
    init_data = chain_hexes_to_bytes([ZERO_ADDRESS, l1_token, messaging_contract.address])
    add_implementation_and_upgrade(
        proxy=proxy,
        new_impl=bridge_impl.address,
        init_data=init_data,
        governor=governor,
    )
    bridge = proxy.replace_abi(abi=bridge_impl.abi)
    bridge.setL2TokenBridge(l2_bridge_fake_address)
    bridge.setMaxTotalBalance(MAX_TVL)
    bridge.setMaxDeposit(1)
    return bridge


@pytest.fixture
def legacy_tester_erc20_bridge(
    governor: EthAccount,
    legacy_erc20_bridge_impl,
    messaging_contract: EthContract,
    mock_erc20_contract: EthContract,
) -> EthContract:
    proxy = deploy_legacy_proxy(governor=governor)
    return setup_bridge(
        governor, proxy, legacy_erc20_bridge_impl, mock_erc20_contract.address, messaging_contract
    )


@pytest.fixture
def legacy_tester_erc20_new_proxy_bridge(
    governor: EthAccount,
    legacy_erc20_bridge_impl: EthContract,
    messaging_contract: EthContract,
    mock_erc20_contract: EthContract,
) -> EthContract:
    proxy = deploy_proxy(governor=governor)
    return setup_bridge(
        governor, proxy, legacy_erc20_bridge_impl, mock_erc20_contract.address, messaging_contract
    )


def test_erc20_bridge_deposit_cancel_upgrade(
    governor: EthAccount,
    mock_erc20_contract: EthContract,
    legacy_tester_erc20_bridge: EthContract,
    compatible_erc20_bridge_impl: EthContract,
    upgrade_eic: EthContract,
    eth_test_utils: EthTestUtils,
):
    """
    Deposit on legacy L1 erc20-bridge contract, upgrade the contract,
    and perform cancel deposit flow on the upgraded contract.
    """
    _filter = legacy_tester_erc20_bridge.w3_contract.events.LogDeposit.createFilter(
        fromBlock="latest"
    )
    legacy_tester_erc20_bridge.setMaxDeposit(2**255)
    legacy_tester_erc20_bridge.setMaxTotalBalance(2**255)
    mock_erc20_contract.approve(legacy_tester_erc20_bridge.w3_contract.address, 2**255)

    # Deposit.
    legacy_tester_erc20_bridge.deposit(
        DEPOSIT_AMOUNT, 0xDABADABADA, transact_args={"value": 500000}
    )
    ev_dict = dict(_filter.get_new_entries()[0].args)
    _nonce = ev_dict["nonce"]
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_erc20_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, governor.address, governor.address])

    # Upgrade.
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    legacy_tester_erc20_bridge = legacy_tester_erc20_bridge.replace_abi(
        compatible_erc20_bridge_impl.abi
    )

    # Send Deposit cancel request.
    legacy_tester_erc20_bridge.legacyDepositCancelRequest(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)
    _before = mock_erc20_contract.balanceOf.call(legacy_tester_erc20_bridge.w3_contract.address)
    with pytest.raises(EthRevertException, match="MESSAGE_CANCELLATION_NOT_ALLOWED_YET"):
        legacy_tester_erc20_bridge.legacyDepositReclaim(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)

    # Advance time for deposit cancel to be reclaimable.
    eth_test_utils.advance_time(7 * 24 * 3600)

    # Deposit reclaim.
    legacy_tester_erc20_bridge.legacyDepositReclaim(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)

    _after = mock_erc20_contract.balanceOf.call(legacy_tester_erc20_bridge.w3_contract.address)
    assert _before - _after == DEPOSIT_AMOUNT


def test_eth_bridge_deposit_cancel_upgrade(
    governor: EthAccount,
    legacy_tester_eth_bridge: EthContract,
    compatible_eth_bridge_impl: EthContract,
    upgrade_eic: EthContract,
    eth_test_utils: EthTestUtils,
):
    """
    Deposit on legacy L1 eth-bridge contract, upgrade the contract,
    and perform cancel deposit flow on the upgraded contract.
    """
    _filter = legacy_tester_eth_bridge.w3_contract.events.LogDeposit.createFilter(
        fromBlock="latest"
    )
    legacy_tester_eth_bridge.setMaxDeposit(2**255)
    legacy_tester_eth_bridge.setMaxTotalBalance(2**255)

    # Deposit.
    legacy_tester_eth_bridge.deposit(DEPOSIT_AMOUNT, 0xDABADABADA, transact_args={"value": 500000})
    ev_dict = dict(_filter.get_new_entries()[0].args)
    _nonce = ev_dict["nonce"]
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_eth_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, governor.address, governor.address])

    # Upgrade.
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_eth_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    legacy_tester_eth_bridge = legacy_tester_eth_bridge.replace_abi(compatible_eth_bridge_impl.abi)

    # Send Deposit cancel request.
    legacy_tester_eth_bridge.legacyDepositCancelRequest(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)
    with pytest.raises(EthRevertException, match="MESSAGE_CANCELLATION_NOT_ALLOWED_YET"):
        legacy_tester_eth_bridge.legacyDepositReclaim(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)

    eth_test_utils.advance_time(7 * 24 * 3600)

    # Reclaim.
    _before = eth_test_utils.w3.eth.get_balance(legacy_tester_eth_bridge.address)
    legacy_tester_eth_bridge.legacyDepositReclaim(DEPOSIT_AMOUNT, 0xDABADABADA, _nonce)
    _after = eth_test_utils.w3.eth.get_balance(legacy_tester_eth_bridge.address)
    assert _before - _after == DEPOSIT_AMOUNT


def test_erc20_bridge_upgrade_happy_path(
    governor,
    mock_erc20_contract,
    legacy_tester_erc20_bridge,
    compatible_erc20_bridge_impl,
    upgrade_eic,
):
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_erc20_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, governor.address, governor.address])
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    upgraded_bridge = legacy_tester_erc20_bridge.replace_abi(compatible_erc20_bridge_impl.abi)
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.isGovernanceAdmin.call(governor.address)
    assert upgraded_bridge.isSecurityAdmin.call(governor.address)


def test_double_upgrade(
    governor,
    mock_erc20_contract,
    legacy_tester_erc20_bridge,
    compatible_erc20_bridge_impl,
    compatible_eth_bridge_impl,
    upgrade_eic,
):
    """
    Test that we successfully upgrade past the first upgrade.
    Validating the isInitialized of the upgraded bridge to be agreeable.
    """
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_erc20_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, governor.address, ZERO_ADDRESS])
    init_data = chain_hexes_to_bytes([ZERO_ADDRESS, governor.address])
    no_init_data = chain_hexes_to_bytes([ZERO_ADDRESS])
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    # Upgrade no. 1 - with EIC.
    upgraded_bridge = legacy_tester_erc20_bridge.replace_abi(compatible_erc20_bridge_impl.abi)
    assert bridge_proxy.implementation.call() == compatible_erc20_bridge_impl.address
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.getStatus.call(L1_TOKEN_ADDRESS_OF_ETH) == 0
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(L1_TOKEN_ADDRESS_OF_ETH) == MAX_UINT
    assert upgraded_bridge.isGovernanceAdmin.call(governor.address)

    # Upgrade no 2. - try again with init data and fail.
    with pytest.raises(EthRevertException, match="UNEXPECTED_INIT_DATA"):
        add_implementation_and_upgrade(
            proxy=bridge_proxy,
            new_impl=compatible_erc20_bridge_impl.address,
            init_data=init_data,
            governor=governor,
        )

    # Upgrade no 3. - change to eth bridge. no init data.
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_eth_bridge_impl.address,
        init_data=no_init_data,
        governor=governor,
    )
    # The impl has changed. the rest didn't (even though the code is of eth legacy bridge).
    assert bridge_proxy.implementation.call() == compatible_eth_bridge_impl.address
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.getStatus.call(L1_TOKEN_ADDRESS_OF_ETH) == 0
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(L1_TOKEN_ADDRESS_OF_ETH) == MAX_UINT

    # Upgrade no 4. - change back to erc20 bridge. no init data.
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=no_init_data,
        governor=governor,
    )
    # The impl has changed back. the rest remained.
    assert bridge_proxy.implementation.call() == compatible_erc20_bridge_impl.address
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.getStatus.call(L1_TOKEN_ADDRESS_OF_ETH) == 0
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(L1_TOKEN_ADDRESS_OF_ETH) == MAX_UINT


def test_erc20_bridge_upgrade_failures(
    governor,
    mock_erc20_contract,
    legacy_tester_erc20_bridge,
    compatible_erc20_bridge_impl,
    upgrade_eic,
):
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_erc20_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address] + 2 * [ZERO_ADDRESS])
    long_eic_init_data = chain_hexes_to_bytes([upgrade_eic.address] + 3 * [ZERO_ADDRESS])
    short_eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, ZERO_ADDRESS])

    # Fail b/c init_data too long.
    with pytest.raises(EthRevertException, match="INVALID_INIT_DATA_LENGTH_64"):
        add_implementation_and_upgrade(
            proxy=bridge_proxy,
            new_impl=compatible_erc20_bridge_impl.address,
            init_data=long_eic_init_data,
            governor=governor,
        )
    # Fail b/c init data too short.
    with pytest.raises(EthRevertException, match="INVALID_INIT_DATA_LENGTH_64"):
        add_implementation_and_upgrade(
            proxy=bridge_proxy,
            new_impl=compatible_erc20_bridge_impl.address,
            init_data=short_eic_init_data,
            governor=governor,
        )
    # Fail b/c maxDeposit == 0 marks a new bridge (not legacy).
    legacy_tester_erc20_bridge.setMaxDeposit(0)
    with pytest.raises(EthRevertException, match="NOT_LEGACY_BRIDGE"):
        add_implementation_and_upgrade(
            proxy=bridge_proxy,
            new_impl=compatible_erc20_bridge_impl.address,
            init_data=eic_init_data,
            governor=governor,
        )
    # Set maxDeposit to overcome.
    legacy_tester_erc20_bridge.setMaxDeposit(1)
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    upgraded_bridge = bridge_proxy.replace_abi(compatible_erc20_bridge_impl.abi)
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.isGovernanceAdmin.call(governor.address)


def test_new_proxy_erc20_bridge_upgrade(
    governor,
    mock_erc20_contract,
    legacy_tester_erc20_new_proxy_bridge,
    compatible_erc20_bridge_impl,
    upgrade_eic,
):
    """
    If the legacy bridge was deployed on a new Proxy,
    the governance init must be done with zero address.
    """
    _abi = load_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_erc20_new_proxy_bridge.replace_abi(_abi)
    assert bridge_proxy.isGovernanceAdmin.call(governor.address), "Roles not initialized!"
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data_with_gov = chain_hexes_to_bytes([upgrade_eic.address] + 2 * [governor.address])
    eic_init_data_with_bad_gov = chain_hexes_to_bytes(3 * [upgrade_eic.address])
    with pytest.raises(EthRevertException, match="ROLES_ALREADY_INITIALIZED"):
        add_implementation_and_upgrade(
            proxy=bridge_proxy,
            new_impl=compatible_erc20_bridge_impl.address,
            init_data=eic_init_data_with_bad_gov,
            governor=governor,
        )
    eic_init_data_no_gov = chain_hexes_to_bytes([upgrade_eic.address, ZERO_ADDRESS, ZERO_ADDRESS])
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_erc20_bridge_impl.address,
        init_data=eic_init_data_no_gov,
        governor=governor,
    )
    upgraded_bridge = bridge_proxy.replace_abi(compatible_erc20_bridge_impl.abi)
    assert upgraded_bridge.getStatus.call(mock_erc20_contract.address) == 2
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(mock_erc20_contract.address) == MAX_TVL
    assert upgraded_bridge.isGovernanceAdmin.call(governor.address)
    assert upgraded_bridge.isSecurityAdmin.call(governor.address)


def test_eth_bridge_upgrade_happy_path(
    governor,
    legacy_tester_eth_bridge,
    compatible_eth_bridge_impl,
    upgrade_eic,
):
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_eth_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes([upgrade_eic.address, governor.address, ZERO_ADDRESS])
    add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_eth_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    upgraded_bridge = legacy_tester_eth_bridge.replace_abi(compatible_eth_bridge_impl.abi)
    assert upgraded_bridge.getStatus.call(L1_TOKEN_ADDRESS_OF_ETH) == 2
    assert upgraded_bridge.maxTotalBalance.call() == MAX_TVL
    assert upgraded_bridge.getMaxTotalBalance.call(L1_TOKEN_ADDRESS_OF_ETH) == MAX_TVL
    assert upgraded_bridge.isGovernanceAdmin.call(governor.address)
    assert upgraded_bridge.isSecurityAdmin.call(governor.address)


def test_deployed(legacy_tester_eth_bridge, legacy_tester_erc20_bridge):
    assert legacy_tester_eth_bridge.address != ZERO_ADDRESS
    assert legacy_tester_erc20_bridge.address != ZERO_ADDRESS
    assert legacy_tester_eth_bridge.isActive.call() == True
    assert legacy_tester_erc20_bridge.isActive.call() == True


def test_legacy_upgrade_event(
    governor,
    regular_user,
    legacy_tester_eth_bridge,
    compatible_eth_bridge_impl,
    upgrade_eic,
):
    _abi = load_legacy_contract("Proxy")["abi"]
    bridge_proxy = legacy_tester_eth_bridge.replace_abi(_abi)
    assert bridge_proxy.implementation.call() != ZERO_ADDRESS
    eic_init_data = chain_hexes_to_bytes(
        [upgrade_eic.address, governor.address, regular_user.address]
    )
    tx_receipt = add_implementation_and_upgrade(
        proxy=bridge_proxy,
        new_impl=compatible_eth_bridge_impl.address,
        init_data=eic_init_data,
        governor=governor,
    )
    as_eic = bridge_proxy.replace_abi(upgrade_eic.abi)
    legacy_upgraded_event = as_eic.get_events(tx=tx_receipt, name="LegacyBridgeUpgraded")[-1]
    assert legacy_upgraded_event == {
        "bridge": legacy_tester_eth_bridge.address,
        "token": L1_TOKEN_ADDRESS_OF_ETH,
    }
