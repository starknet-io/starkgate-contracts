use starknet::{ClassHash, ContractAddress, EthAddress};

/// Interface for contracts that receive tokens with a message from the bridge.
#[starknet::interface]
pub trait ITokenBridgeReceiver<TContractState> {
    fn on_receive(
        ref self: TContractState,
        l2_token: ContractAddress,
        amount: u256,
        depositor: EthAddress,
        message: Span<felt252>,
    ) -> bool;
}

#[starknet::interface]
pub trait ITokenBridge<TContractState> {
    fn get_version(self: @TContractState) -> felt252;
    fn get_identity(self: @TContractState) -> felt252;
    fn get_l1_token(self: @TContractState, l2_token: ContractAddress) -> EthAddress;
    fn get_l2_token(self: @TContractState, l1_token: EthAddress) -> ContractAddress;
    fn get_remaining_withdrawal_quota(self: @TContractState, l1_token: EthAddress) -> u256;
    fn initiate_withdraw(ref self: TContractState, l1_recipient: EthAddress, amount: u256);
    fn initiate_token_withdraw(
        ref self: TContractState, l1_token: EthAddress, l1_recipient: EthAddress, amount: u256,
    );
}

#[starknet::interface]
pub trait ITokenBridgeAdmin<TContractState> {
    fn get_l1_bridge(self: @TContractState) -> EthAddress;
    fn get_erc20_class_hash(self: @TContractState) -> ClassHash;
    fn get_l2_token_governance(self: @TContractState) -> ContractAddress;
    fn set_l1_bridge(ref self: TContractState, l1_bridge_address: EthAddress);
    fn set_erc20_class_hash(ref self: TContractState, erc20_class_hash: ClassHash);
    fn set_l2_token_governance(ref self: TContractState, l2_token_governance: ContractAddress);
    fn enable_withdrawal_limit(ref self: TContractState, l1_token: EthAddress);
    fn disable_withdrawal_limit(ref self: TContractState, l1_token: EthAddress);
    /// Enables locked amount monitoring for a token.
    /// If locked_amount is 0, uses the L2 token's total supply.
    /// Otherwise, uses the provided locked_amount.
    fn enable_locked_amount_monitoring(
        ref self: TContractState, l1_token: EthAddress, locked_amount: u256,
    );
}
