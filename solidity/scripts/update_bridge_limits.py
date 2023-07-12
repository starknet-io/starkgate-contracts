import os

from brownie import Contract, StarknetERC20Bridge, accounts


L1_ADMIN_PRIVATE_KEY = os.environ.get("PARACLEAR_L1_ADMIN_PRIVATE_KEY")
MAX_DEPOSIT = 100_000 * 10**6
MAX_TOTAL_BALANCE = 10_000_000 * 10**6
PROXY_BRIDGE_ADDRESS = ""

def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    admin = accounts.add(L1_ADMIN_PRIVATE_KEY)

    from_admin = {"from": admin}

    # This calls can only be made once we have deployed the L2 Token
    proxy_starknet_bridge = Contract.from_abi(
        "StarknetERC20Bridge",
        PROXY_BRIDGE_ADDRESS,
        StarknetERC20Bridge.abi,
    )
    proxy_starknet_bridge.setMaxTotalBalance(MAX_TOTAL_BALANCE, from_admin)
    proxy_starknet_bridge.setMaxDeposit(MAX_DEPOSIT, from_admin)
