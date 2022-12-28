import os

from pathlib import Path
from typing import Tuple

from starkware.starknet.business_logic.state.state import BlockInfo
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.contract_utils import EventIdentifier
from starkware.starknet.testing.starknet import Starknet

INITIAL_ROOT = 0
INITIAL_BLOCK_NUMBER = -1
UPGRADE_DELAY = 0  # Seconds.

StarknetInitData = Tuple[int, str, int, Tuple[int, int]]

_root = Path(__file__).parent.parent
FILE_DIR = os.path.dirname(__file__)
CAIRO_PATH = [os.path.join(FILE_DIR, "../../cairo/contracts")]


class Uint256:
    """
    Simple Uint256 helper class to help using Staknet Uint256 struct.
    """

    def __init__(self, num: int):
        if num < 0:
            num += 2**256
        # This class is used for testing. Therefore illegal values are intionally allowed.
        # Should we make this class stricter, we have to un-comment the following line.
        # assert 0 <= num < 2 ** 256, f"Number {num} out of range for Uint256"
        self.value = num

    @property
    def low(self):
        return self.value % 2**128

    @property
    def high(self):
        return self.value // 2**128

    @classmethod
    def from_pair(cls, low: int, high: int) -> "Uint256":
        return cls(high << 128 + low)

    def uint256(self) -> Tuple[int, int]:
        """
        The name is uint256, because when we pass in a Uint256 into a starknet contract function,
        we actually have to pass in a tuple like this.
        """
        return (self.low, self.high)


def add_implementation_and_upgrade(proxy, new_impl, init_data, governor, is_finalizing=False):
    proxy.addImplementation.transact(
        new_impl, init_data, is_finalizing, transact_args={"from": governor}
    )
    return proxy.upgradeTo.transact(
        new_impl, init_data, is_finalizing, transact_args={"from": governor}
    )


def create_event_object(_contract: StarknetContract, _event_id: EventIdentifier):
    return _contract.event_manager.get_contract_event(identifier=_event_id)


def assert_events_equal(event_obj_1: type, event_obj_2: type):
    assert event_obj_1 == event_obj_2
    assert type(event_obj_1) == type(event_obj_2)


def starknet_time(starknet: Starknet) -> int:
    """
    Returns starknet last block timestamp.
    """
    _block_info = starknet.state.state.block_info
    return _block_info.block_timestamp


def advance_time(starknet: Starknet, block_time_diff: int, block_num_diff: int = 1):
    """
    Advances timestamp/blocknum on the starknet object.
    """
    assert block_time_diff > 0, f"block_timestamp diff {block_time_diff} too low"
    assert block_num_diff > 0, f"block_number diff {block_num_diff} too low"

    _block_info = starknet.state.state.block_info
    _current_time = _block_info.block_timestamp
    _current_block = _block_info.block_number

    new_block_timestamp = _current_time + block_time_diff
    new_block_number = _current_block + block_num_diff

    new_block_info = BlockInfo.create_for_testing(
        block_number=new_block_number, block_timestamp=new_block_timestamp
    )
    starknet.state.state.block_info = new_block_info


def contract_path(name):
    if name.startswith("tests/"):
        return str(_root / name)
    else:
        return str(_root / "contracts" / name)


def _get_path_from_name(name):
    """Return the contract path by contract name."""
    dirs = ["contracts", "tests/mocks"]
    for dir in dirs:
        for (dirpath, _, filenames) in os.walk(dir):
            for file in filenames:
                if file == f"{name}.cairo":
                    return os.path.join(dirpath, file)

    raise FileNotFoundError(f"Cannot find '{name}'.")


def get_contract_class(contract, is_path=False):
    """Return the contract class from the contract name or path"""
    if is_path:
        path = contract_path(contract)
    else:
        path = _get_path_from_name(contract)
    print("Compiling ", path)
    contract_class = compile_starknet_files(
        files=[path],
        debug_info=True,
        disable_hint_validation=True,
        cairo_path=CAIRO_PATH,
    )
    print("Compiled")
    return contract_class
