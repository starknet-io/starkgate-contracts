import os

from brownie import USDCToken, accounts


L1_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L1_TOKEN_ADDRESS")
L1_ADMIN_PRIVATE_KEY = os.environ.get("PARACLEAR_L1_ADMIN_PRIVATE_KEY")
L1_USER_ADDRESS = os.environ.get("PARACLEAR_L1_USER_ADDRESS")
AMOUNT = os.environ.get("AMOUNT")


def main():
    """
    Add funds to user accounts.
    Requirement: All accounts must be preloaded on brownie
    before running the deploy script.
    """

    admin_account = accounts.add(L1_ADMIN_PRIVATE_KEY)

    from_admin_account = {"from": admin_account}

    usdc = USDCToken.at(L1_TOKEN_ADDRESS)

    # Amount with 6 decimals
    amount = int(AMOUNT) * 10 ** 6
    tx = usdc.mint(L1_USER_ADDRESS, amount, from_admin_account)

    print("tx ", tx)
