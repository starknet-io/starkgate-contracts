import pytest

from starkware.eth.eth_test_utils import EthContract, EthRevertException

CONTRACT_ADDRESS = "0x0000000000000000000000000000000000000003"
CONTRACT_ADDRESS_2 = "0x0000000000000000000000000000000000000005"
CONTRACT_ADDRESS_3 = "0x0000000000000000000000000000000000000007"
CONTRACTS = [CONTRACT_ADDRESS, CONTRACT_ADDRESS_2, CONTRACT_ADDRESS_3]
CANNOT_DEPLOY_BRIDGE = "0x0000000000000000000000000000000000000001"


@pytest.fixture
def bridge_contract(
    governor: EthContract,
    bridge_proxy: EthContract,
    manager_proxy: EthContract,
    registry_proxy: EthContract,
) -> EthContract:
    # TODO : Add implementation.
    return bridge_proxy


def test_enroll_token(
    registry_contract: EthContract,
    manager_contract: EthContract,
    bridge_contract: EthContract,
):
    # Attempt to enroll a token without using the manager contract should result in a
    # revert exception.
    with pytest.raises(EthRevertException, match="ONLY_MANAGER"):
        registry_contract.enrollToken(CONTRACT_ADDRESS, bridge_contract.address)

    # Enroll a token using the manager contract and verify that the bridge address is
    # set correctly.
    manager_contract.enrollTokenBridge(CONTRACT_ADDRESS)
    assert registry_contract.getBridge.call(CONTRACT_ADDRESS) == bridge_contract.address

    # Attempting to enroll an already enrolled token should result in a revert
    # exception.
    with pytest.raises(EthRevertException, match="THE_TOKEN_ALREADY_ENROLLED"):
        manager_contract.enrollTokenBridge(CONTRACT_ADDRESS)


def test_deactivate_token(
    governor: EthContract,
    token_admin: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Enroll a token using the manager contract.
    manager_contract.enrollTokenBridge(CONTRACT_ADDRESS)

    # Attempt to deactivate a token without the correct token admin role should result in
    # a revert exception.
    with pytest.raises(EthRevertException, match="ONLY_TOKEN_ADMIN"):
        manager_contract.deactivateToken(CONTRACT_ADDRESS, transact_args={"from": governor})

    # Deactivate a token using the correct token admin role and verify that the bridge
    # address is updated correctly.
    manager_contract.deactivateToken(CONTRACT_ADDRESS, transact_args={"from": token_admin})
    assert registry_contract.getBridge.call(CONTRACT_ADDRESS) == CANNOT_DEPLOY_BRIDGE

    # Attempting to enroll a token that has been deactivated already should result in a
    # revert exception.
    with pytest.raises(EthRevertException, match="CANNOT_DEPLOY_BRIDGE"):
        manager_contract.enrollTokenBridge(CONTRACT_ADDRESS)


def test_get_deprecated_bridges(
    token_admin: EthContract,
    bridge_contract: EthContract,
    registry_contract: EthContract,
    manager_contract: EthContract,
):
    # Enroll a token using the manager contract and verify initial withdrawal bridges list
    manager_contract.enrollTokenBridge(CONTRACT_ADDRESS)
    assert registry_contract.getWithdrawalBridges.call(CONTRACT_ADDRESS) == [
        bridge_contract.address
    ]

    # Deactivate the token and confirm its bridge remains in the withdrawal bridges list
    manager_contract.deactivateToken(CONTRACT_ADDRESS, transact_args={"from": token_admin})
    assert registry_contract.getWithdrawalBridges.call(CONTRACT_ADDRESS) == [
        bridge_contract.address
    ]

    # Enroll another token and verify that the withdrawal bridges list for the first token
    # remains unchanged.
    manager_contract.enrollTokenBridge(CONTRACT_ADDRESS_2)
    assert registry_contract.getWithdrawalBridges.call(CONTRACT_ADDRESS) == [
        bridge_contract.address
    ]

    # Loop through the list of contract addresses and add them as existing bridges
    for contract_address in CONTRACTS:
        manager_contract.addExistingBridge(
            CONTRACT_ADDRESS_3, contract_address, transact_args={"from": token_admin}
        )
        # Enable the addition of an existing bridge to the token.
        manager_contract.deactivateToken(CONTRACT_ADDRESS_3, transact_args={"from": token_admin})

    # Verify that the withdrawal bridges list for the token matches the added contract addresses
    assert registry_contract.getWithdrawalBridges.call(CONTRACT_ADDRESS_3) == CONTRACTS


def test_remove_self():
    # TODO : Impl.
    assert 1 == 1
