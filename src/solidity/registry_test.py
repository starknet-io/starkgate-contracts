import pytest

from solidity.utils import str_to_felt
from starkware.eth.eth_test_utils import EthContract, EthRevertException, EthAccount, EthTestUtils
from solidity.conftest import (
    ZERO_ADDRESS,
    MAX_UINT,
    L2_TOKEN_CONTRACT,
    HANDLE_TOKEN_ENROLLMENT_SELECTOR,
    UNKNOWN,
    PENDING,
    ACTIVE,
    DEACTIVATED,
)
from starkware.starknet.services.api.messages import StarknetMessageToL2


CANNOT_DEPLOY_BRIDGE = "0x0000000000000000000000000000000000000001"


DAY_IN_SECONDS = 24 * 60 * 60
MAX_PENDING_DURATION = 5 * DAY_IN_SECONDS


def test_enroll_token(
    governor: EthAccount,
    registry_contract: EthContract,
    manager_contract: EthContract,
    erc20_contract_address_list: list[str],
    bridge_contract: EthContract,
):
    # Attempt to enroll a token without using the manager contract should result in a
    # revert exception.
    with pytest.raises(EthRevertException, match="ONLY_MANAGER"):
        registry_contract.enlistToken(erc20_contract_address_list[0], bridge_contract.address)

    # Enroll a token using the manager contract and verify that the bridge address is
    # set correctly.
    manager_contract.enrollTokenBridge.transact(
        erc20_contract_address_list[0], transact_args={"from": governor, "value": 10**16}
    )
    assert (
        registry_contract.getBridge.call(erc20_contract_address_list[0]) == bridge_contract.address
    )

    # Attempting to enroll an already enrolled token should result in a revert
    # exception.
    with pytest.raises(EthRevertException, match="THE_TOKEN_ALREADY_ENROLLED"):
        manager_contract.enrollTokenBridge(erc20_contract_address_list[0])


def test_deactivate_token(
    eth_test_utils: EthTestUtils,
    governor: EthAccount,
    token_admin: EthContract,
    bridge_contract: EthContract,
    erc20_contract_address_list: list[str],
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Enroll a token using the manager contract.
    manager_contract.enrollTokenBridge(
        erc20_contract_address_list[0], transact_args={"from": governor, "value": 10**16}
    )

    # Attempt to deactivate a token without the correct token admin role should result in
    # a revert exception.
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.deactivateToken(
            erc20_contract_address_list[0], transact_args={"from": governor}
        )

    # Deactivate a token using the correct token admin role and verify that the bridge
    # address is updated correctly.
    manager_contract.deactivateToken(
        erc20_contract_address_list[0], transact_args={"from": token_admin}
    )
    assert registry_contract.getBridge.call(erc20_contract_address_list[0]) == CANNOT_DEPLOY_BRIDGE

    # Attempting to enroll a token that has been deactivated already should result in a
    # revert exception.
    with pytest.raises(EthRevertException, match="CANNOT_DEPLOY_BRIDGE"):
        manager_contract.enrollTokenBridge(erc20_contract_address_list[0])


def test_get_withdrawal_bridges(
    governor: EthAccount,
    token_admin: EthContract,
    bridge_contract: EthContract,
    erc20_contract_address_list: list[str],
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Enroll a token using the manager contract and verify initial withdrawal bridges list
    manager_contract.enrollTokenBridge(
        erc20_contract_address_list[0], transact_args={"from": governor, "value": 10**16}
    )
    assert registry_contract.getWithdrawalBridges.call(erc20_contract_address_list[0]) == [
        bridge_contract.address
    ]

    # Deactivate the token and confirm its bridge remains in the withdrawal bridges list
    manager_contract.deactivateToken(
        erc20_contract_address_list[0], transact_args={"from": token_admin}
    )
    assert registry_contract.getWithdrawalBridges.call(erc20_contract_address_list[0]) == [
        bridge_contract.address
    ]

    # Enroll another token and verify that the withdrawal bridges list for the first token
    # remains unchanged.
    manager_contract.enrollTokenBridge(
        erc20_contract_address_list[1], transact_args={"from": governor, "value": 10**16}
    )
    for erc_address in erc20_contract_address_list[:2]:
        assert registry_contract.getWithdrawalBridges.call(erc_address) == [bridge_contract.address]

    # Loop through the list of bridge addresses and add to them the erc_contract.
    test_bridges = erc20_contract_address_list[:]
    for bridge_address in test_bridges:
        manager_contract.addExistingBridge(
            erc20_contract_address_list[2], bridge_address, transact_args={"from": token_admin}
        )
        # Enable the addition of an existing bridge to the token.
        manager_contract.deactivateToken(
            erc20_contract_address_list[2], transact_args={"from": token_admin}
        )

    # Verify that the withdrawal bridges list for the token matches the added bridge addresses
    assert (
        registry_contract.getWithdrawalBridges.call(erc20_contract_address_list[2])
        == erc20_contract_address_list
    )


def test_self_remove(
    eth_test_utils: EthTestUtils,
    governor: EthAccount,
    mock_erc20_contract: EthContract,
    bridge_contract: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == ZERO_ADDRESS
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == UNKNOWN
    manager_contract.enrollTokenBridge(
        mock_erc20_contract.address, transact_args={"from": governor, "value": 10**16}
    )

    # Verify that the token is pending. And the bridge address is set correctly.
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == bridge_contract.address
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == PENDING
    eth_test_utils.advance_time(MAX_PENDING_DURATION + 1)
    mock_erc20_contract.approve(bridge_contract.address, 50, transact_args={"from": governor})
    bridge_contract.deposit(
        mock_erc20_contract.address, 40, 1337, transact_args={"from": governor, "value": 10**16}
    )

    assert registry_contract.getBridge.call(mock_erc20_contract.address) == ZERO_ADDRESS
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == UNKNOWN


def test_checkDeploymentStatus(
    eth_test_utils: EthTestUtils,
    governor: EthAccount,
    mock_erc20_contract: EthContract,
    bridge_contract: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
    messaging_contract: EthContract,
):
    # Set the governor's balance to 10**18.
    eth_test_utils.set_account_balance(address=governor.address, balance=10**18)

    # Enroll a token.
    manager_contract.enrollTokenBridge(
        mock_erc20_contract.address, transact_args={"from": governor, "value": 10**16}
    )
    # Verify that the token is pending. And the bridge address is set correctly.
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == bridge_contract.address
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == PENDING

    # Setup for deposit.
    mock_erc20_contract.approve(bridge_contract.address, 50, transact_args={"from": governor})
    bridge_contract.setMaxTotalBalance(
        mock_erc20_contract.address, MAX_UINT, transact_args={"from": governor}
    )

    # Advance time to the pending deployment expiration boundary.
    eth_test_utils.advance_time(MAX_PENDING_DURATION - 1)

    # Deposit to the bridge. This should trigger the CheckDeploymentStatus function.
    bridge_contract.deposit(
        mock_erc20_contract.address, 40, 1337, transact_args={"from": governor, "value": 10**16}
    )

    # Verify that the token is still pending. And the bridge address is unchanged.
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == bridge_contract.address
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == PENDING

    # Consume the message by L2.
    payload = [
        int(mock_erc20_contract.address, 16),  # token
        str_to_felt(mock_erc20_contract.name.call()),  # name
        str_to_felt(mock_erc20_contract.symbol.call()),  # symbol
        mock_erc20_contract.decimals.call(),  # decimals
    ]
    l1_to_l2_msg = StarknetMessageToL2(
        from_address=int(bridge_contract.address, 16),
        to_address=L2_TOKEN_CONTRACT,
        l1_handler_selector=HANDLE_TOKEN_ENROLLMENT_SELECTOR,
        payload=payload,
        nonce=0,
    )
    deploy_msg_params = (
        l1_to_l2_msg.from_address,
        l1_to_l2_msg.to_address,
        l1_to_l2_msg.l1_handler_selector,
        l1_to_l2_msg.payload,
        l1_to_l2_msg.nonce,
    )
    messaging_contract.mockConsumeMessageToL2.transact(*deploy_msg_params)

    # ReDeposit to the bridge. This should trigger the CheckDeploymentStatus function.
    bridge_contract.deposit(
        mock_erc20_contract.address, 5, 1337, transact_args={"from": governor, "value": 10**16}
    )

    # Verify that the token is active. And the bridge address is unchanged.
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == bridge_contract.address
    assert bridge_contract.getStatus.call(mock_erc20_contract.address) == ACTIVE
