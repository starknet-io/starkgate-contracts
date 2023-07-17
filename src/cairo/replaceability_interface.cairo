use array::ArrayTrait;
use array::SpanTrait;
use option::OptionTrait;

use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};

// TODO delete SpanPartialEq once there's a built-in implementation of PartialEq<Span<felt252>>.
impl SpanPartialEq of PartialEq<Span<felt252>> {
    fn eq(lhs: @Span<felt252>, rhs: @Span<felt252>) -> bool {
        let mut lhs = *lhs;
        let mut rhs = *rhs;
        if lhs.len() != rhs.len() {
            return false;
        }
        loop {
            match lhs.pop_front() {
                Option::Some(x) => {
                    if x != rhs.pop_front().unwrap() {
                        break false;
                    }
                },
                Option::None(()) => {
                    break true;
                },
            };
        }
    }
    fn ne(lhs: @Span<felt252>, rhs: @Span<felt252>) -> bool {
        !(lhs == rhs)
    }
}

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

