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
L2_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L2_TOKEN_ADDRESS")
L2_USER_ADDRESS = os.environ.get("PARACLEAR_L2_USER_ADDRESS")


async def validate():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    usdc_proxy = await Contract.from_address(
        address=L2_TOKEN_ADDRESS,
        client=admin_account_client,
        proxy_config=get_proxy_config(),
    )
    balance_of_invoke = await usdc_proxy.functions['balanceOf'].call(
        int_16(L2_USER_ADDRESS),
    )
    print("balance ", balance_of_invoke, "account ", L2_USER_ADDRESS)


asyncio.run(validate())
