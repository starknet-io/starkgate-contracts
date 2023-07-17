use starknet::ContractAddress;
use starknet::EthAddress;

#[starknet::interface]
trait ITokenBridge<TContractState> {
    fn get_version(self: @TContractState) -> felt252;
    fn get_identity(self: @TContractState) -> felt252;
    fn set_l1_bridge(ref self: TContractState, l1_bridge_address: EthAddress);
    fn set_l2_token(ref self: TContractState, l2_token_address: ContractAddress);
    fn initiate_withdraw(ref self: TContractState, l1_recipient: EthAddress, amount: u256);
}
