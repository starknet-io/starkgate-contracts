from typing import Tuple


from typing import Tuple

from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME
from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.business_logic.state.state import BlockInfo
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.contract_utils import EventIdentifier
from starkware.starknet.testing.starknet import Starknet


def str_to_felt(short_text: str) -> int:
    felt = int.from_bytes(bytes(short_text, encoding="ascii"), "big")
    assert felt < DEFAULT_PRIME, f"{short_text} is too long"
    return felt


def create_event_object(_contract: StarknetContract, _event_id: EventIdentifier):
    return _contract.event_manager.get_contract_event(identifier=_event_id)


def assert_events_equal(event_obj_1: type, event_obj_2: type):
    assert event_obj_1 == event_obj_2
    assert type(event_obj_1) == type(event_obj_2)


def assert_last_event(
    starknet: Starknet,
    contract_: StarknetContract,
    event_name: str,
    from_: int,
    to_: int,
    amount: int,
):
    expected_event = Event(
        from_address=contract_.contract_address,
        keys=[get_selector_from_name(event_name)],
        data=[
            from_,
            to_,
            Uint256(amount).low,
            Uint256(amount).high,
        ],
    )
    assert expected_event == starknet.state.events[-1]


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
