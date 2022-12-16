import os

from brownie import Contract, StarknetERC20Bridge, USDCToken, accounts


L1_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L1_TOKEN_ADDRESS")
L2_USER_ADDRESS = os.environ.get("PARACLEAR_L2_USER_ADDRESS")


def main():
    """
    Add funds to user accounts.
    Requirement: All accounts must be preloaded on brownie
    before running the deploy script.
    """

    admin_account = accounts.load("admin")

    from_admin_account = {"from": admin_account}
    usdc = USDCToken.at(L1_TOKEN_ADDRESS)

    tx = usdc.balanceOf(admin_account, from_admin_account)

    print("old balance ", 100000000000)
    print("new balance ", tx)