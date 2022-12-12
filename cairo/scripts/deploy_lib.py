
import re
from enum import Enum
from typing import Callable, Optional

from starknet_py.constants import RPC_INVALID_MESSAGE_SELECTOR_ERROR
from starknet_py.contract import Contract
from starknet_py.net import AccountClient, KeyPair
from starknet_py.net.client import Client
from starknet_py.net.client_errors import ClientError
from starknet_py.net.client_models import Call, DeployTransactionResponse
from starknet_py.net.gateway_client import GatewayClient
from starknet_py.net.models import Address, StarknetChainId
from starknet_py.net.networks import CustomGatewayUrls, Network
from starknet_py.proxy.contract_abi_resolver import ProxyConfig
from starknet_py.proxy.proxy_check import ArgentProxyCheck, OpenZeppelinProxyCheck, ProxyCheck
from starknet_py.transactions.declare import make_declare_tx
from starknet_py.transactions.deploy import make_deploy_tx
from starkware.python.utils import from_bytes
from starkware.starknet.public.abi import get_selector_from_name

# Private StarkNet
PSN_FEEDER_GATEWAY_URL = "https://potc-testnet.starknet.io/feeder_gateway"
PSN_GATEWAY_URL = "https://potc-testnet.starknet.io/gateway"
POTC_TESTNET = from_bytes(b"PRIVATE_SN_POTC_GOERLI")
UPGRADE_DELAY = 0
EIC_HASH = 0
NOT_FINAL = 0

def int_16(val):
    return int(val, 16)


# For matching existing chainId type
class CustomStarknetChainId(Enum):
    PRIVATE_SN_TESTNET = POTC_TESTNET


# Network
def get_psn_network():
    return CustomGatewayUrls(
        feeder_gateway_url=PSN_FEEDER_GATEWAY_URL, gateway_url=PSN_GATEWAY_URL
    )


class StarkwareETHProxyCheck(ProxyCheck):
    async def implementation_address(self, address: Address, client: Client) -> Optional[int]:
        return await self.get_implementation(
            address=address,
            client=client,
            get_class_func=client.get_class_hash_at,
            regex_err_msg=r"(is not deployed)",
        )

    async def implementation_hash(self, address: Address, client: Client) -> Optional[int]:
        return await self.get_implementation(
            address=address,
            client=client,
            get_class_func=client.get_class_by_hash,
            regex_err_msg=r"(is not declared)",
        )

    @staticmethod
    async def get_implementation(
        address: Address, client: Client, get_class_func: Callable, regex_err_msg: str
    ) -> Optional[int]:
        call = StarkwareETHProxyCheck._get_implementation_call(address=address)
        err_msg = r"(Entry point 0x[0-9a-f]+ not found in contract)|" + regex_err_msg
        try:
            (implementation,) = await client.call_contract(call=call)
            await get_class_func(implementation)
        except ClientError as err:
            if (
                re.search(err_msg, err.message, re.IGNORECASE)
                or err.code == RPC_INVALID_MESSAGE_SELECTOR_ERROR
            ):
                return None
            raise err
        return implementation

    @staticmethod
    def _get_implementation_call(address: Address) -> Call:
        return Call(
            to_addr=address,
            selector=get_selector_from_name("implementation"),
            calldata=[],
        )


def get_proxy_config():
    return ProxyConfig(
        max_steps=5,
        proxy_checks=[StarkwareETHProxyCheck(), ArgentProxyCheck(), OpenZeppelinProxyCheck()],
    )


def get_account_client(
    net: Network, chain: Optional[StarknetChainId], account_address: str, account_key: str
):
    client = GatewayClient(net=net)
    key_pair = KeyPair.from_private_key(key=int_16(account_key))
    account_client = AccountClient(
        client=client,
        address=account_address,
        key_pair=key_pair,
        chain=chain,
    )
    return account_client


async def deploy_with_proxy(name: str, admin_account_client, initialize_data) -> DeployTransactionResponse:
    contract_declare_tx = make_declare_tx(
        compilation_source=["contracts/" + name], cairo_path=['contracts/']
    )
    contract_abi = contract_declare_tx.contract_class.abi
    contract_declare_result = await admin_account_client.declare(contract_declare_tx)
    print(contract_declare_tx)
    print(f"{name} declare hash:", hex(contract_declare_result.class_hash))
    print(f"{name} tx hash:", hex(contract_declare_result.transaction_hash))

    print("Waiting for tx to be accepted...")
    await admin_account_client.wait_for_tx(contract_declare_result.transaction_hash, wait_for_accept=True)
    print(f"{name} contract declared")

    proxy_deploy_tx = make_deploy_tx(
        compilation_source=['contracts/upgradability_proxy/proxy.cairo'],
        constructor_calldata=[UPGRADE_DELAY],
        cairo_path=['contracts/'],
    )
    print(f"Deploying {name} proxy contract...")
    proxy_deploy_result = await admin_account_client.deploy(proxy_deploy_tx)
    print(proxy_deploy_result)
    print("Proxy contract address:", hex(proxy_deploy_result.contract_address))
    print("Proxy tx hash:", hex(proxy_deploy_result.transaction_hash))

    print("Waiting for tx to be accepted...")
    await admin_account_client.wait_for_tx(
        proxy_deploy_result.transaction_hash,
        wait_for_accept=True
    )
    print("Proxy contract is deployed!")

    contract_with_proxy = Contract(
        address=proxy_deploy_result.contract_address, abi=contract_abi, client=admin_account_client
    )
    print("Contract address for initializing:", hex(contract_with_proxy.address))

    init_governance_invoke = await contract_with_proxy.functions["init_governance"].invoke()
    print("Waiting for init_governance tx to be accepted...", hex(init_governance_invoke.hash))
    await init_governance_invoke.wait_for_acceptance(wait_for_accept=True)
    implementation_data = [
        contract_declare_result.class_hash,
        EIC_HASH,
        initialize_data,
        NOT_FINAL,
    ]
    add_implementation_invoke = await contract_with_proxy.functions["add_implementation"].invoke(
        implementation_data
    )
    print("Waiting for add_implementation tx to be accepted...", hex(add_implementation_invoke.hash))
    await add_implementation_invoke.wait_for_acceptance(wait_for_accept=True)
    upgrade_to_invoke = await contract_with_proxy.functions["upgrade_to"].invoke(
        implementation_data
    )
    print("Waiting for upgrade_to tx to be accepted...", hex(upgrade_to_invoke.hash))
    await upgrade_to_invoke.wait_for_acceptance(wait_for_accept=True)

    return contract_with_proxy
