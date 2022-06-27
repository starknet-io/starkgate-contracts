import asyncio
import os
import shutil
from argparse import ArgumentParser

from starkware.eth.eth_test_utils import EthTestUtils
from starkware.starknet.apps.starkgate.cairo.contracts import bridge_contract_class
from starkware.starknet.apps.starkgate.eth.contracts import StarknetERC20Bridge, StarknetEthBridge
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.std_contracts.ERC20.contracts import erc20_contract_class
from starkware.starknet.testing.starknet import Starknet

SOLIDITY_ETH_BRIDGE_FILE_NAME = "StarknetEthBridge"
SOLIDITY_ERC20_BRIDGE_FILE_NAME = "StarknetERC20Bridge"
CAIRO_BRIDGE_FILE_NAME = "token_bridge"
CAIRO_ERC20_FILE_NAME = "ERC20"


def parse_args():
    parser = ArgumentParser(description="Copy Starkgate artifacts with versions")

    parser.add_argument("--solidity_bridge_artifacts_dir", type=str, required=True)
    parser.add_argument("--cairo_bridge_artifacts_dir", type=str, required=True)
    parser.add_argument("--cairo_erc20_artifacts_dir", type=str, required=True)
    parser.add_argument("--output_dir", type=str, required=True)

    return parser.parse_args()


def get_solidity_bridge_version(compiled_bridge_contract: dict, contract_name: str):
    with EthTestUtils.context_manager() as eth_test_utils:
        contract = eth_test_utils.accounts[0].deploy(compiled_bridge_contract)
        identify_str = contract.identify.call()
    words = identify_str.split("_")
    error_message = (
        f"Expected contract id of the format StarkWare_{contract_name}_year_version, "
        f"got {identify_str}"
    )
    assert len(words) == 4, error_message
    assert words[0] == "StarkWare", error_message
    assert words[1] == contract_name, error_message
    assert words[2].isdigit() and 2022 <= int(words[2]) <= 2100, f"Invalid year {words[2]}"
    assert words[3].isdigit() and 1 <= int(words[3]) <= 2**10, f"Invalid version {words[3]}"
    return words[3]


async def get_cairo_version(contract_class: ContractClass):
    starknet = await Starknet.empty()
    contract = await starknet.deploy(constructor_calldata=[], contract_class=contract_class)
    return (await contract.get_version().call()).result.version


async def main():
    args = parse_args()

    os.makedirs(name=os.path.join(args.output_dir, "cairo"), exist_ok=True)
    os.makedirs(name=os.path.join(args.output_dir, "eth"), exist_ok=True)
    for bridge_file_name, compiled_bridge_contract in [
        (SOLIDITY_ETH_BRIDGE_FILE_NAME, StarknetEthBridge),
        (SOLIDITY_ERC20_BRIDGE_FILE_NAME, StarknetERC20Bridge),
    ]:
        version = get_solidity_bridge_version(
            compiled_bridge_contract=compiled_bridge_contract, contract_name=bridge_file_name
        )
        shutil.copy(
            os.path.join(args.solidity_bridge_artifacts_dir, f"{bridge_file_name}.json"),
            os.path.join(args.output_dir, "eth", f"{bridge_file_name}_{version}.json"),
        )
    shutil.copy(
        os.path.join(args.cairo_bridge_artifacts_dir, f"{CAIRO_BRIDGE_FILE_NAME}.json"),
        os.path.join(
            args.output_dir,
            "cairo",
            f"{CAIRO_BRIDGE_FILE_NAME}_{await get_cairo_version(bridge_contract_class)}.json",
        ),
    )
    shutil.copy(
        os.path.join(args.cairo_erc20_artifacts_dir, f"{CAIRO_ERC20_FILE_NAME}.json"),
        os.path.join(
            args.output_dir,
            "cairo",
            f"{CAIRO_ERC20_FILE_NAME}_{await get_cairo_version(erc20_contract_class)}.json",
        ),
    )


if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    loop.run_until_complete(main())
    loop.close()
