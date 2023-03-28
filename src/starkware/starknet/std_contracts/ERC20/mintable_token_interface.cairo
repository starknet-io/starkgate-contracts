%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace IMintableToken {
    func permissionedMint(account: felt, amount: Uint256) {
    }

    func permissionedBurn(account: felt, amount: Uint256) {
    }
}
