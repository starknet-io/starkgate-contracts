use starknet::ClassHash;
use starknet::ContractAddress;
use starknet::EthAddress;

// TODO - split into two interfaces - one for operations and one for admin tasks.
#[starknet::interface]
trait ITokenBridge<TContractState> {
    fn get_version(self: @TContractState) -> felt252;
    fn get_identity(self: @TContractState) -> felt252;
    fn get_erc20_class_hash(self: @TContractState) -> ClassHash;
    fn get_l1_token_address(self: @TContractState, l2_token_address: ContractAddress) -> EthAddress;
    fn get_l2_token_address(self: @TContractState, l1_token_address: EthAddress) -> ContractAddress;
    fn get_remaining_withdrawal_quota(
        self: @TContractState, l2_token_address: ContractAddress
    ) -> u256;
    fn set_l1_bridge(ref self: TContractState, l1_bridge_address: EthAddress);
    fn set_erc20_class_hash(ref self: TContractState, erc20_class_hash: ClassHash);
    fn initiate_withdraw(
        ref self: TContractState, l1_recipient: EthAddress, token: EthAddress, amount: u256
    );
    fn apply_withdrawal_limit(ref self: TContractState, token: EthAddress, applied_state: bool);
}
