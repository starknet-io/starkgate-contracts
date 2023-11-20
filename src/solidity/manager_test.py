import pytest

from starkware.eth.eth_test_utils import EthContract, EthRevertException, EthAccount
from solidity.conftest import BLOCKED_TOKEN, TOKEN_ADDRESS, BRIDGE_ADDRESS, DEFAULT_DEPOSIT_FEE


def test_addExistingBridge(
    governor: EthAccount,
    token_admin: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Attempt to add a bridge without being the token admin.
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.addExistingBridge(TOKEN_ADDRESS, BRIDGE_ADDRESS)

    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.addExistingBridge(
            TOKEN_ADDRESS, BRIDGE_ADDRESS, transact_args={"from": governor}
        )

    manager_contract.addExistingBridge(
        TOKEN_ADDRESS, BRIDGE_ADDRESS, transact_args={"from": token_admin}
    )
    # Check that the bridge was added.
    assert registry_contract.getBridge.call(TOKEN_ADDRESS) == BRIDGE_ADDRESS

    # Attempt to add a token that already has a bridge.
    with pytest.raises(EthRevertException, match="TOKEN_ALREADY_ENROLLED"):
        manager_contract.addExistingBridge(
            TOKEN_ADDRESS, BRIDGE_ADDRESS, transact_args={"from": token_admin}
        )


def test_blockToken(
    governor: EthAccount,
    token_admin: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Attempt to block a token without being the token admin.
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.blockToken(TOKEN_ADDRESS)
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.blockToken(TOKEN_ADDRESS, transact_args={"from": governor})

    manager_contract.blockToken(TOKEN_ADDRESS, transact_args={"from": token_admin})
    # Check that the token was blocked.
    assert registry_contract.getBridge.call(TOKEN_ADDRESS) == BLOCKED_TOKEN
    with pytest.raises(EthRevertException, match="CANNOT_DEPLOY_BRIDGE"):
        manager_contract.enrollTokenBridge(TOKEN_ADDRESS)

    # Attempt to block a token that is already blocked.
    with pytest.raises(EthRevertException, match="TOKEN_ALREADY_BLOCKED"):
        manager_contract.blockToken(TOKEN_ADDRESS, transact_args={"from": token_admin})

    # Add a custom bridge for the token.
    manager_contract.addExistingBridge(
        TOKEN_ADDRESS, BRIDGE_ADDRESS, transact_args={"from": token_admin}
    )

    # Check that the token was added.
    assert registry_contract.getBridge.call(TOKEN_ADDRESS) == BRIDGE_ADDRESS

    # Attempt to block a token that has a bridge.
    with pytest.raises(EthRevertException, match="CANNOT_BLOCK_TOKEN_IN_SERVICE"):
        manager_contract.blockToken(TOKEN_ADDRESS, transact_args={"from": token_admin})

    manager_contract.deactivateToken(TOKEN_ADDRESS, transact_args={"from": token_admin})
    assert registry_contract.getBridge.call(TOKEN_ADDRESS) == BLOCKED_TOKEN

    with pytest.raises(EthRevertException, match="CANNOT_BLOCK_DEACTIVATED_TOKEN"):
        manager_contract.blockToken(TOKEN_ADDRESS, transact_args={"from": token_admin})


def test_deactivate_token(
    governor: EthAccount,
    token_admin: EthContract,
    bridge_contract: EthContract,
    erc20_contract_address_list: list[str],
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Attempt to deactivate a token without being the token admin.
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.deactivateToken(erc20_contract_address_list[0])
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.deactivateToken(
            erc20_contract_address_list[0], transact_args={"from": governor}
        )

    # Attempt to deactivate a token that is not enrolled should result in a revert
    # exception.
    with pytest.raises(EthRevertException, match="TOKEN_NOT_ENROLLED"):
        manager_contract.deactivateToken(
            erc20_contract_address_list[0], transact_args={"from": token_admin}
        )

    # Enroll a token using the manager contract.
    manager_contract.enrollTokenBridge(
        erc20_contract_address_list[0],
        transact_args={"from": governor, "value": DEFAULT_DEPOSIT_FEE},
    )
    assert (
        registry_contract.getBridge.call(erc20_contract_address_list[0]) == bridge_contract.address
    )

    manager_contract.deactivateToken(
        erc20_contract_address_list[0], transact_args={"from": token_admin}
    )
    assert registry_contract.getBridge.call(erc20_contract_address_list[0]) == BLOCKED_TOKEN

    with pytest.raises(EthRevertException, match="CANNOT_DEPLOY_BRIDGE"):
        manager_contract.enrollTokenBridge(
            erc20_contract_address_list[0],
            transact_args={"from": governor, "value": DEFAULT_DEPOSIT_FEE},
        )

    with pytest.raises(EthRevertException, match="TOKEN_ALREADY_DEACTIVATED"):
        manager_contract.deactivateToken(
            erc20_contract_address_list[0], transact_args={"from": token_admin}
        )

    manager_contract.blockToken(erc20_contract_address_list[1], transact_args={"from": token_admin})

    with pytest.raises(EthRevertException, match="TOKEN_ALREADY_BLOCKED"):
        manager_contract.deactivateToken(
            erc20_contract_address_list[1], transact_args={"from": token_admin}
        )


def test_deactivate_token_deposit_not_allowed(
    governor: EthAccount,
    token_admin: EthContract,
    bridge_contract: EthContract,
    mock_erc20_contract: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Enroll a token using the manager contract.
    manager_contract.enrollTokenBridge(
        mock_erc20_contract.address, transact_args={"from": governor, "value": DEFAULT_DEPOSIT_FEE}
    )
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == bridge_contract.address
    mock_erc20_contract.approve(bridge_contract.address, 50, transact_args={"from": governor})
    bridge_contract.deposit(
        mock_erc20_contract.address,
        40,
        1337,
        transact_args={"from": governor, "value": DEFAULT_DEPOSIT_FEE},
    )

    manager_contract.deactivateToken(
        mock_erc20_contract.address, transact_args={"from": token_admin}
    )
    assert registry_contract.getBridge.call(mock_erc20_contract.address) == BLOCKED_TOKEN
    with pytest.raises(EthRevertException, match="TOKEN_NOT_SERVICED"):
        bridge_contract.deposit(
            mock_erc20_contract.address,
            5,
            1337,
            transact_args={"from": governor, "value": DEFAULT_DEPOSIT_FEE},
        )
