import asyncio
import os

from starknet_py.contract import Contract
from deploy_lib import (
    CustomStarknetChainId,
    get_account_client,
    get_psn_network,
)
from proxy_config import get_proxy_config
from utils import int_16, to_uint256

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")
L1_USER_ADDRESS = os.environ.get("PARACLEAR_L1_USER_ADDRESS")
AMOUNT = os.environ.get("AMOUNT")


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    bridge_proxy = await Contract.from_address(
        address=L2_BRIDGE_ADDRESS,
        client=admin_account_client,
        proxy_config=get_proxy_config(),
    )
    initiate_withdraw_invoke = await bridge_proxy.functions['initiate_withdraw'].invoke(
        int_16(L1_USER_ADDRESS),
        to_uint256(AMOUNT),
        max_fee=int(1e16),
    )
    print(
        "Waiting for initiate_withdraw_invoke tx to be accepted...",
        hex(initiate_withdraw_invoke.hash),
    )
    await initiate_withdraw_invoke.wait_for_acceptance(wait_for_accept=True)


asyncio.run(deploy())
