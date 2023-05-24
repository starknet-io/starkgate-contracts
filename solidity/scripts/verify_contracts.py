import os

from brownie import Contract, Proxy, StarknetERC20Bridge, accounts
from eth_abi import encode

def main():
    """
    Deployment and setup script for L1 Bridge.
    """
    # token = StarknetERC20Bridge.at("0x69a6D6B80bE5eF3330cF5fb948Bf8Cc1A6bdcB65")
    # StarknetERC20Bridge.publish_source(token)
    # L1 USDC token needs to be deployed before the L1 Bridge

    proxy = Proxy.at("0x69a6D6B80bE5eF3330cF5fb948Bf8Cc1A6bdcB65")
    Proxy.publish_source(proxy)
