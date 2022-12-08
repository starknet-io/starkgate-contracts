%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin

@storage_var
func _initialized() -> (res: felt) {
}

@view
func initialized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (res: felt) {
    let (res) = _initialized.read();
    return (res=res);
}

func only_uninitialized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (initialized_: felt) = initialized();
    with_attr error_message("ALREADY_INITIALIZED") {
        assert initialized_ = FALSE;
    }
    return ();
}

func set_initialized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    only_uninitialized();
    _initialized.write(TRUE);
    return ();
}
