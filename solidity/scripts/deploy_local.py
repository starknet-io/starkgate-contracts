import os

from brownie import Contract, USDCToken, Proxy, StarknetERC20Bridge, accounts
from eth_abi import encode


UPGRADE_DELAY = 0
PRIVATE_STARKNET_CORE_CONTRACT = "0xEc86FAD336de60C953828b5cDb1EAc1D68fBdc82"


def main():
    """
    Deployment and setup script for L1 Bridge. Requires extra setup due to ERC20 contract
    needed to be availablei n the local blockchain in order to set it up on the bridge.
    """

    l2_bridge_contract_address = "0x012"
    admin_account = accounts.load("admin")

    from_admin_account = {"from": admin_account}
    usdc_contact = USDCToken.deploy(from_admin_account)
    starknet_bridge = StarknetERC20Bridge.deploy(
        from_admin_account,
        # publish_source=True
    )

    init_data = encode(
        ['address', 'address', 'address'],
        [
            "0x0000000000000000000000000000000000000000",
            usdc_contact.address,
            PRIVATE_STARKNET_CORE_CONTRACT,
        ],
    )

    proxy = Proxy.deploy(
        UPGRADE_DELAY,
        from_admin_account,
        # publish_source=True,
    )
    proxy.addImplementation(
        starknet_bridge.address,
        init_data,
        False,
        from_admin_account,
    )

    proxy.upgradeTo(
        starknet_bridge.address,
        init_data,
        False,
        from_admin_account,
    )

    proxy_starknet_bridge = Contract.from_abi(
        "StarknetERC20Bridge",
        proxy.address,
        StarknetERC20Bridge.abi,
    )
    proxy_starknet_bridge.setL2TokenBridge(l2_bridge_contract_address, from_admin_account)
    proxy_starknet_bridge.setMaxTotalBalance(2**256 - 1, from_admin_account)
    proxy_starknet_bridge.setMaxDeposit(2**256 - 1, from_admin_account)