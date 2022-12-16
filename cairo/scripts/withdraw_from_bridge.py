import asyncio
import os

from starknet_py.contract import Contract
from starknet_py.transactions.declare import make_declare_tx
from deploy_lib import (
    CustomStarknetChainId,
    get_account_client,
    get_psn_network,
    int_16,
    to_uint256,
)

ADMIN_ACCOUNT_ADDRESS = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_ADDRESS")
ADMIN_ACCOUNT_KEY = os.environ.get("PARACLEAR_PSN_ADMIN_ACCOUNT_KEY")
L2_BRIDGE_ADDRESS = os.environ.get("PARACLEAR_L2_BRIDGE_ADDRESS")
L1_USER_ADDRESS = os.environ.get("PARACLEAR_L1_USER_ADDRESS")


async def deploy():
    admin_account_client = get_account_client(
        get_psn_network(),
        CustomStarknetChainId.PRIVATE_SN_TESTNET,
        ADMIN_ACCOUNT_ADDRESS,
        ADMIN_ACCOUNT_KEY,
    )

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

    initiate_withdraw_invoke = await bridge.functions['initiate_withdraw'].invoke(
        int_16(L1_USER_ADDRESS),
        to_uint256(100000000000),
        max_fee=int(1e16),
    )
    print(
        "Waiting for initiate_withdraw_invoke tx to be accepted...",
        hex(initiate_withdraw_invoke.hash),
    )
    await initiate_withdraw_invoke.wait_for_acceptance(wait_for_accept=True)

    print("Bridge contract:", hex(bridge.address))


asyncio.run(deploy())
