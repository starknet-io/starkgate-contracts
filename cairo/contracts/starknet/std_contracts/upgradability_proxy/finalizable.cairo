%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin

@storage_var
func _finalized() -> (res: felt) {
}

@view
func finalized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (res: felt) {
    let (res) = _finalized.read();
    return (res=res);
}

func not_finalized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (finalized_: felt) = finalized();
    with_attr error_message("FINALIZED") {
        assert finalized_ = FALSE;
    }
    return ();
}

func finalize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    not_finalized();
    _finalized.write(TRUE);
    return ();
}
