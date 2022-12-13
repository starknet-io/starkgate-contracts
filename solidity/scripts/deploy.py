import os

from brownie import Contract, Proxy, StarknetERC20Bridge, accounts
from eth_abi import encode


UPGRADE_DELAY = 0
PRIVATE_STARKNET_CORE_CONTRACT = "0xEc86FAD336de60C953828b5cDb1EAc1D68fBdc82"
USDC_CONTRACT_ADDRESS = "0xf4242092b79BDF3662F784A9c25ce5CD0D6fAE0B"
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")
# Not needed but the contract initializer expects at least one address for it
# even though the value of numOfSubContracts is set to 0. #contracts.StarknetTokenBridge.sol LN50.
EIC_CONTRACT_PLACEHOLDER = "0x0000000000000000000000000000000000000000"


def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    admin = accounts.load("admin")

    from_admin = {"from": admin}
    starknet_bridge = StarknetERC20Bridge.deploy(
        from_admin,
        # publish_source=True
    )

    init_data = encode(
        ['address', 'address', 'address'],
        [
            EIC_CONTRACT_PLACEHOLDER,
            USDC_CONTRACT_ADDRESS,
            PRIVATE_STARKNET_CORE_CONTRACT,
        ],
    )

    proxy = Proxy.deploy(
        UPGRADE_DELAY,
        from_admin,
        # publish_source=True,
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

    proxy_starknet_bridge = Contract.from_abi(
        "StarknetERC20Bridge",
        proxy.address,
        StarknetERC20Bridge.abi,
    )
    proxy_starknet_bridge.setL2TokenBridge(L2_BRIDGE_ADDRESS, from_admin)
    proxy_starknet_bridge.setMaxTotalBalance(2**256 - 1, from_admin)
    proxy_starknet_bridge.setMaxDeposit(2**256 - 1, from_admin)