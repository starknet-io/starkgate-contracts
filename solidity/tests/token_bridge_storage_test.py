import random

import pytest

from starkware.eth.eth_test_utils import EthContract, EthTestUtils
from starkware.python.utils import from_bytes
from starkware.starknet.apps.starkgate.eth.test_contracts import (
    StarknetERC20BridgeTester,
    StarknetEthBridgeTester,
)

LAYOUT_SIZE = 0


@pytest.fixture(scope="session")
def eth_tester(eth_test_utils: EthTestUtils) -> EthContract:
    contract = eth_test_utils.accounts[0].deploy(StarknetEthBridgeTester)
    return contract


@pytest.fixture(scope="session")
def erc20_tester(eth_test_utils: EthTestUtils) -> EthContract:
    contract = eth_test_utils.accounts[0].deploy(StarknetERC20BridgeTester)
    return contract


@pytest.fixture
def test_contract(request, eth_tester, erc20_tester) -> EthContract:
    return eth_tester if hasattr(request, "param") and request.param == "eth" else erc20_tester


@pytest.mark.parametrize("test_contract", ["eth", "erc20"], indirect=True)
def test_storage_bounds_check(test_contract: EthContract, eth_test_utils: EthTestUtils):
    bread_crumb = random.randrange(10000, 20000)
    test_contract.setMarker.transact(bread_crumb)
    w3 = eth_test_utils.w3
    address = test_contract.address
    extracted_crumb = from_bytes(w3.eth.get_storage_at(address, LAYOUT_SIZE))
    assert extracted_crumb == bread_crumb
