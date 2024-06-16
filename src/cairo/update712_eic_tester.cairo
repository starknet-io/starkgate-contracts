/// This contract is a testing stub for the eip712 update eic.
#[cfg(test)]
#[starknet::interface]
trait ITester<TContractState> {
    fn get_dapp_name(self: @TContractState) -> felt252;
    fn get_dapp_version(self: @TContractState) -> felt252;
}


#[cfg(test)]
#[starknet::contract]
mod Update712EICTester {
    use core::result::ResultTrait;
    use debug::PrintTrait;
    use super::ITester;
    use starknet::{syscalls::library_call_syscall, get_block_timestamp};
    use super::super::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait,
        EIC_INITIALIZE_SELECTOR, IMPLEMENTATION_EXPIRATION
    };

    #[storage]
    struct Storage {
        // --- EIP712 ---
        EIP712_name: felt252,
        EIP712_version: felt252,
        // --- Replaceability ---
        // Delay in seconds before performing an upgrade.
        upgrade_delay: u64,
        // Timestamp by which implementation can be activated.
        impl_activation_time: LegacyMap<felt252, u64>,
        // Timestamp until which implementation can be activated.
        impl_expiration_time: LegacyMap<felt252, u64>,
        // Is the implementation finalized.
        finalized: bool,
    }

    // -- Replaceability --

    // Derives the implementation_data key.
    fn calc_impl_key(implementation_data: ImplementationData) -> felt252 {
        // Hash the implementation_data to obtain a key.
        let mut hash_input = ArrayTrait::new();
        implementation_data.serialize(ref hash_input);
        poseidon::poseidon_hash_span(hash_input.span())
    }

    #[abi(embed_v0)]
    impl Tester of ITester<ContractState> {
        fn get_dapp_name(self: @ContractState) -> felt252 {
            self.EIP712_name.read()
        }
        fn get_dapp_version(self: @ContractState) -> felt252 {
            self.EIP712_version.read()
        }
    }

    #[abi(embed_v0)]
    impl Replaceable of IReplaceable<ContractState> {
        fn get_upgrade_delay(self: @ContractState) -> u64 {
            self.upgrade_delay.read()
        }

        // Returns the implementation activation time.
        fn get_impl_activation_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.read(impl_key)
        }

        // Adds a new implementation.
        fn add_new_implementation(
            ref self: ContractState, implementation_data: ImplementationData
        ) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();
            let activation_time = get_block_timestamp() + self.get_upgrade_delay();
            let expiration_time = activation_time + IMPLEMENTATION_EXPIRATION;
            // TODO -  add an assertion that the `implementation_data.impl_hash` is declared.
            self.set_impl_activation_time(:implementation_data, :activation_time);
            self.set_impl_expiration_time(:implementation_data, :expiration_time);
        }

        // Removes an existing implementation.
        fn remove_implementation(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Read implementation activation time.
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);

            if (impl_activation_time.is_non_zero()) {
                self.set_impl_activation_time(:implementation_data, activation_time: 0);
                self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
            }
        }

        // Replaces the non-finalized current implementation to one that was previously added and
        // whose activation time had passed.
        fn replace_to(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Validate implementation is not finalized.
            assert(!self.is_finalized(), 'FINALIZED');

            let now = get_block_timestamp();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);
            let impl_expiration_time = self.get_impl_expiration_time(:implementation_data);

            // Zero activation time means that this implementation & init vector combination
            // was not previously added.
            assert(impl_activation_time.is_non_zero(), 'UNKNOWN_IMPLEMENTATION');

            assert(impl_activation_time <= now, 'NOT_ENABLED_YET');
            assert(now <= impl_expiration_time, 'IMPLEMENTATION_EXPIRED');

            // Finalize imeplementation, if needed.
            if (implementation_data.final) {
                self.finalize();
            }

            // Handle EIC.
            match implementation_data.eic_data {
                Option::Some(eic_data) => {
                    // Wrap the calldata as a span, as preperation for the library_call_syscall
                    // invocation.
                    let mut calldata_wrapper = ArrayTrait::new();
                    eic_data.eic_init_data.serialize(ref calldata_wrapper);

                    // Invoke the EIC's initialize function as a library call.
                    let mut res = library_call_syscall(
                        class_hash: eic_data.eic_hash,
                        function_selector: EIC_INITIALIZE_SELECTOR,
                        calldata: calldata_wrapper.span()
                    );
                    if (!res.is_ok()) {
                        let mut err = res.unwrap_err();
                        let err_msg: felt252 = *err[0].into();
                        err_msg.print();
                        assert(false, err_msg);
                    }
                },
                Option::None(()) => {}
            };

            // Replace the class hash.
            let result = starknet::replace_class_syscall(implementation_data.impl_hash);
            assert(result.is_ok(), 'REPLACE_CLASS_HASH_FAILED');

            // Remove implementation data, as it was comsumed.
            self.set_impl_activation_time(:implementation_data, activation_time: 0);
            self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
        }
    }

    #[generate_trait]
    impl internals of _internals {
        fn only_upgrade_governor(self: @ContractState) {}

        // Returns if finalized.
        fn is_finalized(self: @ContractState) -> bool {
            self.finalized.read()
        }

        // Sets the implementation as finalized.
        fn finalize(ref self: ContractState) {
            self.finalized.write(true);
        }


        // Sets the implementation activation time.
        fn set_impl_activation_time(
            ref self: ContractState, implementation_data: ImplementationData, activation_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.write(impl_key, activation_time);
        }

        // Returns the implementation activation time.
        fn get_impl_expiration_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.read(impl_key)
        }

        // Sets the implementation expiration time.
        fn set_impl_expiration_time(
            ref self: ContractState, implementation_data: ImplementationData, expiration_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.write(impl_key, expiration_time);
        }
    }
}
