%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace ITokenBridge:
    func get_governor() -> (res : felt):
    end

    func get_l1_bridge() -> (res : felt):
    end

    func get_l2_token() -> (res : felt):
    end

    func set_l1_bridge(l1_bridge_address : felt):
    end

    func set_l2_token(l2_token_address : felt):
    end

    func initiate_withdraw(l1_recipient : felt, amount : Uint256):
    end

    func get_version() -> (version : felt):
    end

    func get_identity() -> (identity : felt):
    end
end
