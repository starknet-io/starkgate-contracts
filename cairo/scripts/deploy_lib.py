from enum import Enum
from pathlib import Path
from typing import Optional

from starknet_py.common import create_compiled_contract
from starknet_py.contract import Contract, DeclareResult
from starknet_py.net import AccountClient, KeyPair
from starknet_py.net.gateway_client import GatewayClient
from starknet_py.net.models import StarknetChainId
from starknet_py.net.networks import CustomGatewayUrls, Network
from starkware.python.utils import from_bytes
from starkware.starknet.public.abi import AbiType
from utils import int_16

# Private StarkNet
PSN_FEEDER_GATEWAY_URL = "https://potc-testnet.starknet.io/feeder_gateway"
PSN_GATEWAY_URL = "https://potc-testnet.starknet.io/gateway"
POTC_TESTNET = from_bytes(b"PRIVATE_SN_POTC_GOERLI")

UNIVERSAL_DEPLOYER_ADDRESS = int_16(
    "0x445d879cd83e4ff91399f1f11c1efec034faed9802bdc622f37809886e5d730"
)

UPGRADE_DELAY = 0
EIC_HASH = 0
NOT_FINAL = 0


# For matching existing chainId type
class CustomStarknetChainId(Enum):
    PRIVATE_SN_TESTNET = POTC_TESTNET


# Network
def get_psn_network():
    return CustomGatewayUrls(
        feeder_gateway_url=PSN_FEEDER_GATEWAY_URL, gateway_url=PSN_GATEWAY_URL
    )


def get_compiled_contract(name) -> str:
    dir = Path(__file__).parent
    contract_file = dir / f"../artifacts/{name}.json"
    compiled_contract = contract_file.read_text()
    return compiled_contract


def get_account_client(
    net: Network,
    chain: Optional[StarknetChainId],
    account_address: str,
    account_key: str,
    tx_version: int = 1,
):
    client = GatewayClient(net=net)
    key_pair = KeyPair.from_private_key(key=int_16(account_key))
    account_client = AccountClient(
        client=client,
        address=account_address,
        key_pair=key_pair,
        chain=chain,
        supported_tx_version=tx_version,
    )
    return account_client


async def deploy_with_proxy(name: str, admin_account_client, init_vector) -> Contract:
    # Declare implementation
    compiled_contract = get_compiled_contract(name)
    declare_result = await Contract.declare(
        account=admin_account_client, compiled_contract=compiled_contract, max_fee=int(1e16)
    )
    print(f"{name} class hash:", hex(declare_result.class_hash))
    print(f"{name} declare tx hash:", hex(declare_result.hash))
    await declare_result.wait_for_acceptance(wait_for_accept=True)
    print(f"{name} contract declared")

    # Declare proxy
    compiled_proxy_contract = get_compiled_contract("proxy")
    proxy_declare_result = await Contract.declare(
        account=admin_account_client, compiled_contract=compiled_proxy_contract, max_fee=int(1e16)
    )
    print("Proxy class hash:", hex(proxy_declare_result.class_hash))
    print("Proxy declare tx hash:", hex(proxy_declare_result.hash))
    await proxy_declare_result.wait_for_acceptance(wait_for_accept=True)
    print("Proxy contract declared")

    # Deploy
    print(f"Deploying {name} proxy contract...")
    proxy_deploy_result = await proxy_declare_result.deploy(
        constructor_args=[UPGRADE_DELAY],
        deployer_address=UNIVERSAL_DEPLOYER_ADDRESS,
        max_fee=int(1e16),
    )
    print(proxy_deploy_result)
    print("Proxy contract address:", hex(proxy_deploy_result.deployed_contract.address))
    print("Proxy deploy tx hash:", hex(proxy_deploy_result.hash))

    print("Waiting for tx to be accepted...")
    await proxy_deploy_result.wait_for_acceptance(wait_for_accept=True)

    proxy_contract = Contract(
        address=proxy_deploy_result.deployed_contract.address,
        client=admin_account_client,
        abi=create_compiled_contract(None, compiled_proxy_contract).abi,
    )
    print("Proxy contract is deployed!")

    # Init governance
    init_governance_invoke = await proxy_contract.functions["init_governance"].invoke(max_fee=int(1e16))
    print("Waiting for init_governance tx to be accepted...", hex(init_governance_invoke.hash))
    await init_governance_invoke.wait_for_acceptance(wait_for_accept=True)

    # Add implementation
    implementation_data = [
        declare_result.class_hash,
        EIC_HASH,
        init_vector,
        NOT_FINAL,
    ]
    add_implementation_invoke = await proxy_contract.functions["add_implementation"].invoke(
        *implementation_data,
        max_fee=int(1e16)
    )
    print("Waiting for add_implementation tx to be accepted...", hex(add_implementation_invoke.hash))
    await add_implementation_invoke.wait_for_acceptance(wait_for_accept=True)

    # Upgrade to
    upgrade_to_invoke = await proxy_contract.functions["upgrade_to"].invoke(
        *implementation_data,
        max_fee=int(1e16)
    )
    print("Waiting for upgrade_to tx to be accepted...", hex(upgrade_to_invoke.hash))
    await upgrade_to_invoke.wait_for_acceptance(wait_for_accept=True)

    return proxy_contract
