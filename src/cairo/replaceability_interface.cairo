use array::ArrayTrait;
use array::SpanTrait;
use option::OptionTrait;

use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};

#[derive(Copy, Drop, Serde, PartialEq)]
struct ImplementationData {
    impl_hash: ClassHash,
    // TODO we don't need init data without eic_hash, so consolidate these into a more meaningful 
    // data structure.
    eic_hash: ClassHash,
    eic_init_data: Span<felt252>,
    final: bool
}

#[starknet::interface]
trait IReplaceable<TContractState> {
    fn get_upgrade_delay(self: @TContractState) -> u64;
    fn get_impl_activation_time(
        self: @TContractState, implementation_data: ImplementationData
    ) -> u64;
    fn add_new_implementation(ref self: TContractState, implementation_data: ImplementationData);
    fn remove_implementation(ref self: TContractState, implementation_data: ImplementationData);
    fn replace_to(ref self: TContractState, implementation_data: ImplementationData);
}

