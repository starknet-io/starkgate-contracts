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
L1_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L1_BRIDGE_ADDRESS")
L2_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L2_TOKEN_ADDRESS")


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    initialize_data = [
        admin_account_client.address
    ]
    bridge = await deploy_with_proxy(
        'token_bridge.cairo',
        admin_account_client,
        initialize_data,
    )
    tx = bridge.functions['set_l1_bridge'].invoke(L1_BRIDGE_ADDRESS)
    print("Waiting for set_l1_bridge tx to be accepted...", hex(tx.hash))

    tx = bridge.functions['set_l2_token'].invoke(L2_TOKEN_ADDRESS)
    print("Waiting for set_l2_token tx to be accepted...", hex(tx.hash))

    print("Bridge contract:", hex(bridge.contract_address))


asyncio.run(deploy())