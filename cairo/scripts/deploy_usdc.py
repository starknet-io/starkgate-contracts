import asyncio
import os

from starknet_py.cairo.felt import encode_shortstring

from deploy_lib import (
    CustomStarknetChainId,
    deploy_with_proxy,
    get_account_client,
    get_psn_network,
)
from utils import int_16

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    init_vector = [
        encode_shortstring("USDC"),
        encode_shortstring("USDC"),
        6,
        int_16(L2_BRIDGE_ADDRESS),
    ]
    usdc_proxy = await deploy_with_proxy(
        "ERC20",
        admin_account_client,
        init_vector,
    )
    print("USDC contract:", hex(usdc_proxy.address))


asyncio.run(deploy())
