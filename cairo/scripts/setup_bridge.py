import asyncio
import os

from starknet_py.contract import Contract
from deploy_lib import (
    CustomStarknetChainId,
    get_account_client,
    get_psn_network,
)
from proxy_config import get_proxy_config
from utils import int_16

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L1_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L1_BRIDGE_ADDRESS")
L2_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L2_TOKEN_ADDRESS")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")


async def setup_bridge():
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

    # We can only call this once we have the L1 Bridge deployed,
    # L2 Bridge deployed and L2 Token deployed.
    set_l1_bridge_invoke = await bridge_proxy.functions["set_l1_bridge"].invoke(
        int_16(L1_BRIDGE_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l1_bridge tx to be accepted...", hex(set_l1_bridge_invoke.hash))
    await set_l1_bridge_invoke.wait_for_acceptance(wait_for_accept=True)
    set_l2_token_invoke = await bridge_proxy.functions["set_l2_token"].invoke(
        int_16(L2_TOKEN_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l2_token tx to be accepted...", hex(set_l2_token_invoke.hash))
    await set_l2_token_invoke.wait_for_acceptance()


asyncio.run(setup_bridge())
