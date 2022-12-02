%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin

@storage_var
func _finalized() -> (res : felt):
end

@view
func finalized{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (res : felt):
    let (res) = _finalized.read()
    return (res=res)
end

func not_finalized{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (finalized_ : felt) = finalized()
    with_attr error_message("FINALIZED"):
        assert finalized_ = FALSE
    end
    return ()
end

func finalize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    not_finalized()
    _finalized.write(TRUE)
    return ()
end
