%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace ITokenBridge {
    func get_governor() -> (res: felt) {
    }

    func get_l1_bridge() -> (res: felt) {
    }

    func get_l2_token() -> (res: felt) {
    }

    func set_l1_bridge(l1_bridge_address: felt) {
    }

    func set_l2_token(l2_token_address: felt) {
    }

    func initiate_withdraw(l1_recipient: felt, amount: Uint256) {
    }

    func get_version() -> (version: felt) {
    }

    func get_identity() -> (identity: felt) {
    }
}
