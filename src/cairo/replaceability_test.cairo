// A dummy contract used for testing EIC.
#[starknet::contract]
mod EICTestContract {
    use super::super::replaceability_interface::IEICInitializable;

    #[storage]
    struct Storage {
        // Arbitrary storage variable from TokenBridge to be modified by the tests.
        upgrade_delay: u64,
    }

    #[external(v0)]
    impl EICInitializable of IEICInitializable<ContractState> {
        // Adds the value in eic_init_data to the storage variable.
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 1, 'EIC_INIT_DATA_LEN_MISMATCH');
            let upgrade_delay = self.upgrade_delay.read();
            self.upgrade_delay.write(upgrade_delay + (*eic_init_data[0]).try_into().unwrap());
        }
    }
}


#[cfg(test)]
mod replaceability_test {
    use array::ArrayTrait;
    use array::SpanTrait;

    use core::traits::Into;
    use core::result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use serde::Serde;

    use starknet::class_hash::{ClassHash, class_hash_const};
    use starknet::{ContractAddress, get_caller_address};

    use super::EICTestContract;

    use super::super::token_bridge::TokenBridge;
    use super::super::token_bridge::TokenBridge::{
        Event, ImplementationAdded, ImplementationRemoved, ImplementationReplaced,
        ImplementationFinalized
    };
    use super::super::test_utils::test_utils::{
        caller, not_caller, initial_owner, set_contract_address_as_caller,
        set_contract_address_as_not_caller, pop_and_deserialize_last_event, pop_last_k_events,
        deserialize_event, get_replaceable, set_caller_as_upgrade_governor, deploy_token_bridge,
        DEFAULT_UPGRADE_DELAY
    };
    use super::super::replaceability_interface::{
        EICData, ImplementationData, IReplaceable, IReplaceableDispatcher,
        IReplaceableDispatcherTrait
    };
    use super::super::roles_interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use super::super::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };


    const EIC_UPGRADE_DELAY_ADDITION: u64 = 5;


    fn get_token_bridge_impl_hash() -> ClassHash {
        TokenBridge::TEST_CLASS_HASH.try_into().unwrap()
    }

    fn dummy_implementation_data(final: bool) -> ImplementationData {
        // Set the eic_init_data calldata.
        let calldata = array!['dummy', 'arbitrary', 'values'];

        ImplementationData {
            impl_hash: get_token_bridge_impl_hash(), eic_data: Option::None(()), final: final
        }
    }

    fn get_dummy_nonfinal_implementation_data() -> ImplementationData {
        dummy_implementation_data(final: false)
    }

    fn get_dummy_final_implementation_data() -> ImplementationData {
        dummy_implementation_data(final: true)
    }


    fn get_dummy_eic_implementation_data() -> ImplementationData {
        // Set the eic_init_data calldata.
        let calldata = array![EIC_UPGRADE_DELAY_ADDITION.into()];

        let eic_data = EICData {
            eic_hash: EICTestContract::TEST_CLASS_HASH.try_into().unwrap(),
            eic_init_data: calldata.span()
        };

        ImplementationData {
            impl_hash: get_token_bridge_impl_hash(), eic_data: Option::Some(eic_data), final: false
        }
    }


    fn assert_finalized_status(expected: bool, contract_address: ContractAddress) {
        // Validate implementation finalized status.
        let orig = get_caller_address();
        starknet::testing::set_contract_address(contract_address);
        let token_bridge_state = TokenBridge::contract_state_for_testing();
        assert(
            TokenBridge::InternalFunctions::is_finalized(@token_bridge_state) == expected,
            'FINALIZED_VALUE_MISMATCH'
        );
        starknet::testing::set_contract_address(orig);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_get_upgrade_delay() {
        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);

        // Validate the upgrade delay.
        assert(
            token_bridge.get_upgrade_delay() == DEFAULT_UPGRADE_DELAY, 'DEFAULT_UPGRADE_DELAY_ERROR'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Check implementation time pre addition.
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        token_bridge.add_new_implementation(:implementation_data);

        // Check implementation time post addition.
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == DEFAULT_UPGRADE_DELAY,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::ImplementationAdded(
                ImplementationAdded { implementation_data: implementation_data }
            ),
            'ImplementationAdded Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        let not_governor_address = not_caller();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.add_new_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Remove implementation that was not previously added.
        // TODO the following should NOT emit an event.
        token_bridge.remove_implementation(:implementation_data);
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Add implementation.
        token_bridge.add_new_implementation(:implementation_data);

        // Validate event emission for adding the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::ImplementationAdded(
                ImplementationAdded { implementation_data: implementation_data }
            ),
            'ImplementationAdded Error'
        );

        // Remove implementation
        token_bridge.remove_implementation(:implementation_data);

        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission for removing the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::ImplementationRemoved(
                ImplementationRemoved { implementation_data: implementation_data }
            ),
            'ImplementationRemoved Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        token_bridge.remove_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_with_eic() {
        // Tests replacing an implementation to a non-final implementation using EIC, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a dummy implementation replacement with eic
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the eic effect

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_eic_implementation_data();

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);
        let updated_upgrade_delay = token_bridge.get_upgrade_delay();

        assert(
            updated_upgrade_delay == DEFAULT_UPGRADE_DELAY + EIC_UPGRADE_DELAY_ADDITION,
            'EIC_FAILED'
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_nonfinal() {
        // Tests replacing an implementation to a non-final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a non-final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implemenation is not final

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        token_bridge.replace_to(:implementation_data);

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::ImplementationReplaced(
                ImplementationReplaced { implementation_data: implementation_data }
            ),
            'ImplementationReplaced Error'
        );
    // TODO check the new impl hash.
    // TODO check the new impl is not final.
    // TODO check that ImplementationFinalized is NOT emitted.
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_remove_impl_on_replace() {
        // Tests that when replacing class-hash, the impl time is reset to zero.
        // 1. deploys a replaceable contract
        // 2. generates implementation replacement to the same classhash.
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the impl time is now zero.
        // 7. Fails to replace to this impl.

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        // Prepare implementation data with the same class hash (repalce to self).
        let implementation_data = get_dummy_nonfinal_implementation_data();
        let other_implementation_data = get_dummy_final_implementation_data();

        // Add implementations.
        token_bridge.add_new_implementation(:implementation_data);
        token_bridge.add_new_implementation(implementation_data: other_implementation_data);
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) != 0, 'EXPECTED_NON_ZERO'
        );
        assert(
            token_bridge
                .get_impl_activation_time(implementation_data: other_implementation_data) != 0,
            'EXPECTED_NON_ZERO'
        );

        // Advance time to enable implementation.
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        token_bridge.replace_to(:implementation_data);

        // Check enabled timestamp zerod for repalced to impl, and non-zero for other.
        assert(token_bridge.get_impl_activation_time(:implementation_data) == 0, 'EXPECTED_ZERO');
        assert(
            token_bridge
                .get_impl_activation_time(implementation_data: other_implementation_data) != 0,
            'EXPECTED_NON_ZERO'
        );

        // Should revert with UNKNOWN_IMPLEMENTATION as replace_to removes the implementation.
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('IMPLEMENTATION_EXPIRED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_expire_impl() {
        // Tests that when impl class-hash cannot be replaced to after expiration.

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        // Prepare implementation data with the same class hash (repalce to self).
        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Add implementation.
        token_bridge.add_new_implementation(:implementation_data);
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) != 0, 'EXPECTED_NON_ZERO'
        );

        // Advance time to enable implementation.
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        token_bridge.replace_to(:implementation_data);

        // Check enabled timestamp zerod for repalced to impl, and non-zero for other.
        assert(token_bridge.get_impl_activation_time(:implementation_data) == 0, 'EXPECTED_ZERO');

        // Add implementation for 2md time.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(
            DEFAULT_UPGRADE_DELAY + 1 + DEFAULT_UPGRADE_DELAY + 14 * 3600 * 24 + 2
        );

        // Should revert on expired_impl.
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_final() {
        // Tests replacing an implementation to a final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implementation is final

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_implementation_data();

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);

        // Validate event emissions -- replacement and finalization of the implementation.
        let implementation_events = pop_last_k_events(address: token_bridge_address, k: 2);

        let implementation_replaced_event = deserialize_event(
            raw_event: *implementation_events.at(0)
        );
        assert(
            implementation_replaced_event == ImplementationReplaced {
                implementation_data: implementation_data
            },
            'ImplementationReplaced Error'
        );

        let implementation_finalized_event = deserialize_event(
            raw_event: *implementation_events.at(1)
        );
        assert(
            implementation_finalized_event == ImplementationFinalized {
                impl_hash: implementation_data.impl_hash
            },
            'ImplementationFinalized Error'
        );
        // TODO check the new impl hash.

        // Validate finalized status.
        assert_finalized_status(expected: true, contract_address: token_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('FINALIZED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_already_final() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_implementation_data();

        // Set the contract address to be of the token bridge, so we can call the internal
        // finalize() function on the replaceable contract state.
        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::InternalFunctions::finalize(ref token_bridge_state);

        set_contract_address_as_caller();
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_unknown_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_implementation_data();

        // Calling replace_to without previously adding the implementation.
        token_bridge.replace_to(:implementation_data);
    }
}
