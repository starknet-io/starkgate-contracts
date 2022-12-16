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
# L1_BRIDGE_ADDRESS = "0xd256efe3d853cd5422f7dd6ddf4d8fb73a1c7ce61cce1c00142b4c156351bf"
# L2_TOKEN_ADDRESS = "0x66aee3c05916df7361197c0ffed6a0fdeb0b2b09b3a9bab48ac19505b82fcd"
# L2_BRIDGE_ADDRESS = "0xd256efe3d853cd5422f7dd6ddf4d8fb73a1c7ce61cce1c00142b4c156351bf"


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )
    # initialize_data = [
    #     admin_account_client.address
    # ]
    # bridge = await deploy_with_proxy(
    #     'token_bridge.cairo',
    #     admin_account_client,
    #     initialize_data,
    # )

    # For first deploymenet, we first deploy
    # L2 Bridge -> L2 USDC -> L1 Bridge -> Setup L2 Bridge
    contract_declare_tx = make_declare_tx(
        compilation_source=["contracts/token_bridge.cairo"],
        cairo_path=['contracts/'],
    )
    contract_abi = contract_declare_tx.contract_class.abi
    bridge = Contract(
        address=L2_BRIDGE_ADDRESS,
        abi=contract_abi,
        client=admin_account_client,
    )

    set_l1_bridge_invoke = await bridge.functions['set_l1_bridge'].invoke(
        int_16(L1_BRIDGE_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l1_bridge tx to be accepted...", hex(set_l1_bridge_invoke.hash))
    await set_l1_bridge_invoke.wait_for_acceptance(wait_for_accept=True)
    set_l2_token_invoke = await bridge.functions['set_l2_token'].invoke(
        int_16(L2_TOKEN_ADDRESS),
        max_fee=int(1e16),
    )
    print("Waiting for set_l2_token tx to be accepted...", hex(set_l2_token_invoke.hash))
    await set_l2_token_invoke.wait_for_acceptance(wait_for_accept=True)

    print("Bridge contract:", hex(bridge.address))


asyncio.run(deploy())
