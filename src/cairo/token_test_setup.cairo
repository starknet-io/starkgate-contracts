// This functions is called in order to set some storage variables and then replace to the token
// bridge. When legacy bridge is being upgraded the l2_token and the l1_l2_token_map and
// l2_l1_token_map should be initialized. Since, there is not option to write to a storage variable
// from tests, this contract sets the relevant storage variables and then replaces to the token
//  bridge.
#[cfg(test)]
#[starknet::contract]
mod TokenTestSetup {
    use core::starknet::SyscallResultTrait;
    use core::array::SpanTrait;
    use zeroable::Zeroable;
    use super::super::token_bridge::TokenBridge;

    use starknet::{ContractAddress, EthAddress};
    #[storage]
    struct Storage {
        l2_token: ContractAddress,
        l1_l2_token_map: LegacyMap<EthAddress, ContractAddress>,
        l2_l1_token_map: LegacyMap<ContractAddress, EthAddress>,
    }

    #[external(v0)]
    fn set_l2_token_and_replace(
        ref self: ContractState,
        l1_token: EthAddress,
        l2_token: ContractAddress,
        l2_token_for_mapping: ContractAddress
    ) {
        self.l2_token.write(l2_token);
        self.l1_l2_token_map.write(l1_token, l2_token_for_mapping);
        self.l2_l1_token_map.write(l2_token_for_mapping, l1_token);
        let result = starknet::replace_class_syscall(
            TokenBridge::TEST_CLASS_HASH.try_into().unwrap()
        );
    }
}
