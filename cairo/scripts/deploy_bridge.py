import asyncio
import os

from deploy_lib import (
    CustomStarknetChainId,
    deploy_with_proxy,
    get_account_client,
    get_psn_network,
)

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")


async def deploy_bridge():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    init_vector = [
        admin_account_client.address
    ]
    bridge_proxy = await deploy_with_proxy(
        "token_bridge",
        admin_account_client,
        init_vector,
    )
    print("Bridge contract:", hex(bridge_proxy.address))


asyncio.run(deploy_bridge())
