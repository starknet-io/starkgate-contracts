import asyncio
import os

from starknet_py.contract import Contract
from starknet_py.transactions.declare import make_declare_tx
from deploy_lib import (
    CustomStarknetChainId,
    get_account_client,
    get_psn_network,
    int_16,
)

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
    contract_declare_tx = make_declare_tx(
        compilation_source=["contracts/starknet/std_contracts/ERC20/ERC20.cairo"],
        cairo_path=['contracts/'],
    )
    contract_abi = contract_declare_tx.contract_class.abi
    usdc = Contract(
        address=L2_TOKEN_ADDRESS,
        abi=contract_abi,
        client=admin_account_client,
    )
    balance_of_invoke = await usdc.functions['balanceOf'].call(
        int_16(L2_USER_ADDRESS),
    )
    print("balance ", balance_of_invoke, "account ", L2_USER_ADDRESS)


asyncio.run(validate())
