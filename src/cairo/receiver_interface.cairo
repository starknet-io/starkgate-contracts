use starknet::{ContractAddress, EthAddress};


#[starknet::interface]
trait IMsgReceiver<TContractState> {
    fn on_receive(
        self: @TContractState,
        l2_token: ContractAddress,
        amount: u256,
        depositor: EthAddress,
        message: Span<felt252>
    ) -> bool;
}

