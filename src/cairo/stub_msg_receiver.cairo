#[starknet::contract]
mod StubMsgReceiver {
    use core::array::SpanTrait;
    use zeroable::Zeroable;
    use super::super::receiver_interface::IMsgReceiver;

    use starknet::{ContractAddress, EthAddress};
    #[storage]
    struct Storage {}


    #[external(v0)]
    impl ReceiverImpl of IMsgReceiver<ContractState> {
        fn on_receive(
            self: @ContractState,
            l2_token: ContractAddress,
            amount: u256,
            depositor: EthAddress,
            message: Span<felt252>
        ) -> bool {
            let first_element = *message[0];
            // A scenario where on_receive fails.
            assert(first_element != 'ASSERT', 'First element is ASSERT');
            // A scenario where on_receive returns false.
            if (first_element == 'RETURN FALSE') {
                return false;
            }
            // A scenario where on_receive returns true.
            true
        }
    }
}
