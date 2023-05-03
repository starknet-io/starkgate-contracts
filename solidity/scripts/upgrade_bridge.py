import os

from brownie import Contract, Proxy, StarknetERC20Bridge, accounts
from eth_abi import encode

L1_ADMIN_PRIVATE_KEY = os.environ.get("PARACLEAR_L1_ADMIN_PRIVATE_KEY")
L1_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L1_BRIDGE_ADDRESS")
L1_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L1_TOKEN_ADDRESS")

# Not needed but the contract initializer expects at least one address for it
# even though the value of numOfSubContracts is set to 0. #contracts.StarknetTokenBridge.sol LN50.
EIC_CONTRACT_PLACEHOLDER = "0x0000000000000000000000000000000000000000"


def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    admin = accounts.add(L1_ADMIN_PRIVATE_KEY)

    from_admin = {"from": admin}
    starknet_bridge = StarknetERC20Bridge.deploy(from_admin)

    # Already initialized
    init_data = encode(
        ['address'],
        [EIC_CONTRACT_PLACEHOLDER],
    )

    proxy = Contract.from_abi(
        "Proxy",
        L1_BRIDGE_ADDRESS,
        Proxy.abi,
    )
    proxy.addImplementation(
        starknet_bridge.address,
        init_data,
        False,
        from_admin,
    )
    proxy.upgradeTo(
        starknet_bridge.address,
        init_data,
        False,
        from_admin,
    )
