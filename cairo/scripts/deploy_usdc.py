import asyncio
import os

from starknet_py.cairo.felt import encode_shortstring

from deploy_lib import (
    CustomStarknetChainId,
    deploy_with_proxy,
    get_account_client,
    get_psn_network,
    int_16,
)

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")
# L2_BRIDGE_ADDRESS = "0x070e8a66585fde35fc444d13360d5f7cfb0384a56a14786c869e0bce7315d8a3"


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    initialize_data = [
        encode_shortstring('USDC'),
        encode_shortstring('USDC'),
        6,
        int_16(L2_BRIDGE_ADDRESS),  # The bridge is the minter and burner for the erc20 contract
    ]
    usdc_proxy = await deploy_with_proxy(
        'ERC20/ERC20.cairo',
        admin_account_client,
        initialize_data,
    )
    # Logs
    print("USDC contract:", hex(usdc_proxy.address))


asyncio.run(deploy())