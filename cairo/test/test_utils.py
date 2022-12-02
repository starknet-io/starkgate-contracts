from starkware.starknet.business_logic.state.state import BlockInfo
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.contract_utils import EventIdentifier
from starkware.starknet.testing.starknet import Starknet


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
