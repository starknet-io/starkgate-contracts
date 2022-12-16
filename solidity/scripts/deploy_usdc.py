import os

from brownie import  USDCToken, accounts

L1_TOKEN_ADDRESS = "0x0d4ED9d0E0Ca8bF6f640256B298a2690DEC5f3cC"


def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    admin = accounts.load("admin")

    from_admin = {"from": admin}
    tx = USDCToken.deploy(
        from_admin,
        # publish_source=True
    )
