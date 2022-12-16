import os

from brownie import USDCToken, accounts


L1_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L1_TOKEN_ADDRESS")
USER_PRIVATE_KEY = os.environ.get("USER_PRIVATE_KEY")


def main():
    """
    Add funds to user accounts.
    Requirement: All accounts must be preloaded on brownie
    before running the deploy script.
    """

    user_account = accounts.add(USER_PRIVATE_KEY)

    from_user_account = {"from": user_account}
    usdc = USDCToken.at(L1_TOKEN_ADDRESS)

    tx = usdc.balanceOf(user_account, from_user_account)

    # Return usdc balance without added precision.
    print("new balance ", tx * 10 ** -6)
