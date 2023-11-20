use starknet::{ContractAddress, EthAddress};

#[starknet::interface]
trait ITokenTestSetup<TContractState> {
    fn set_l2_token_and_replace(
        ref self: TContractState,
        l1_token: EthAddress,
        l2_token: ContractAddress,
        l2_token_for_mapping: ContractAddress
    );
}
