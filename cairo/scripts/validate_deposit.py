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
L2_TOKEN_ADDRESS = os.environ.get("PARACLEAR_L2_TOKEN_ADDRESS")
# L1_BRIDGE_ADDRESS = "0xebed7bd1Ed1410ac16f1E0099D1898Afe8ACC049"
# L2_TOKEN_ADDRESS = "0x04a40a41af4889edd652fbb2c4ca79095ec292cc61863f2646e8cba09d56aec0"
# L2_BRIDGE_ADDRESS = "0x070e8a66585fde35fc444d13360d5f7cfb0384a56a14786c869e0bce7315d8a3"


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
        int_16(ADMIN_ACCOUNT_ADDRESS),
    )
    print(balance_of_invoke)
    # allowance_invoke = await usdc.functions['increaseAllowance'].invoke(
    #     int_16(ADMIN_ACCOUNT_ADDRESS),
    #     to_uint256("1"),
    #     max_fee=int(1e16),
    # )
    # print(
    #     "Waiting for initiate_withdraw_invoke tx to be accepted...",
    #     allowance_invoke.hash,
    # )
    # await allowance_invoke.wait_for_acceptance(wait_for_accept=True)
    # print(allowance_invoke)


asyncio.run(validate())