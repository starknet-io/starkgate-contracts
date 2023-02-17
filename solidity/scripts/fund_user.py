import os

from brownie import Contract, StarknetERC20Bridge, USDCToken, accounts


L1_ADMIN_PRIVATE_KEY = os.environ.get("PARACLEAR_L1_ADMIN_PRIVATE_KEY")
L1_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L1_BRIDGE_ADDRESS")
L1_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L1_TOKEN_ADDRESS")
L2_USER_ADDRESS = os.environ.get("PARACLEAR_L2_USER_ADDRESS")
AMOUNT = os.environ.get("AMOUNT")


def main():
    """
    Add funds to user accounts.
    Requirement: All accounts must be preloaded on brownie
    before running the deploy script.
    """

    admin_account = accounts.add(L1_ADMIN_PRIVATE_KEY)

    from_admin_account = {"from": admin_account}

    bridge = Contract.from_abi(
        "StarknetERC20Bridge",
        L1_BRIDGE_ADDRESS,
        StarknetERC20Bridge.abi,
    )
    usdc = USDCToken.at(L1_TOKEN_ADDRESS)

    # <amount> USDC with 6 decimals
    amount = int(AMOUNT) * 10 ** 6
    usdc.mint(L2_USER_ADDRESS, amount, from_admin_account)
    usdc.approve(bridge, amount, from_admin_account)

    bridge.deposit(amount, L2_USER_ADDRESS, from_admin_account)
