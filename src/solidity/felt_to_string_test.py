import pytest

from starkware.eth.eth_test_utils import EthContract, EthRevertException, EthAccount
from solidity.utils import felt_to_str, load_contract, str_to_felt


FeltToStrTester = load_contract("FeltToStrTester")
simple_str = "Wen Token?"
too_long_text = 10 * "1234567890"


@pytest.fixture(scope="session")
def tester(governor: EthAccount) -> EthContract:
    return governor.deploy(FeltToStrTester)


def test_simple_string(tester):
    assert tester.testStrToFelt.call(simple_str) == str_to_felt(simple_str)
    assert felt_to_str(tester.testStrToFelt.call(simple_str)) == simple_str


def test_safe_simple_string(tester):
    assert tester.testSafeStrToFelt.call(simple_str) == tester.testStrToFelt.call(simple_str)


def test_long_str(tester):
    with pytest.raises(EthRevertException, match="STRING_TOO_LONG"):
        tester.testStrToFelt.call(too_long_text)

    with pytest.raises(EthRevertException, match="STRING_TOO_LONG"):
        tester.testStrToFelt.call(too_long_text[:32])

    assert tester.testSafeStrToFelt.call(too_long_text) == tester.testStrToFelt.call(
        too_long_text[:31]
    )
    assert felt_to_str(tester.testSafeStrToFelt.call(too_long_text)) == too_long_text[:31]
