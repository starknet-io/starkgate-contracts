import asyncio
import os

from starknet_py.contract import Contract
from starknet_py.transactions.declare import make_declare_tx
from deploy_lib import (
    CustomStarknetChainId,
    deploy_with_proxy,
    get_account_client,
    get_psn_network,
    int_16,
)

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L1_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L1_BRIDGE_ADDRESS")
L2_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L2_TOKEN_ADDRESS")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")
L1_BRIDGE_ADDRESS = "0xebed7bd1Ed1410ac16f1E0099D1898Afe8ACC049"
L2_TOKEN_ADDRESS = "0x04a40a41af4889edd652fbb2c4ca79095ec292cc61863f2646e8cba09d56aec0"
L2_BRIDGE_ADDRESS = "0x070e8a66585fde35fc444d13360d5f7cfb0384a56a14786c869e0bce7315d8a3"


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

    # For first deploymenet, we first deploy
    # L2 Bridge -> L2 USDC -> L1 Bridge -> Setup L2 Bridge
    # contract_declare_tx = make_declare_tx(
    #     compilation_source=["contracts/token_bridge.cairo"],
    #     cairo_path=['contracts/'],
    # )
    # contract_abi = contract_declare_tx.contract_class.abi
    # bridge = Contract(
    #     address=L2_BRIDGE_ADDRESS,
    #     abi=contract_abi,
    #     client=admin_account_client,
    # )

    tx = await bridge.functions['set_l1_bridge'].invoke(
        int_16(L1_BRIDGE_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l1_bridge tx to be accepted...", hex(tx.hash))

    tx = await bridge.functions['set_l2_token'].invoke(
        int_16(L2_TOKEN_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l2_token tx to be accepted...", hex(tx.hash))

    print("Bridge contract:", hex(bridge.address))


asyncio.run(deploy())
