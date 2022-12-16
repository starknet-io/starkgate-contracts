import os

from brownie import  USDCToken, accounts

L1_ADMIN_PRIVATE_KEY = os.environ.get("PARACLEAR_L1_ADMIN_PRIVATE_KEY")


def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    admin = accounts.add(L1_ADMIN_PRIVATE_KEY)

    from_admin = {"from": admin}
    USDCToken.deploy(from_admin)
