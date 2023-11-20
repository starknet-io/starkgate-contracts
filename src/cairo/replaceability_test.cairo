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
    use starknet::{ContractAddress, get_contract_address};

    use super::EICTestContract;

    use openzeppelin::token::erc20_v070::erc20::ERC20;
    use openzeppelin::token::erc20_v070::erc20::ERC20::{
        Event, ImplementationAdded, ImplementationRemoved, ImplementationReplaced,
        ImplementationFinalized
    };
    use super::super::token_bridge::TokenBridge;
    use super::super::test_utils::test_utils::{
        caller, not_caller, initial_owner, set_contract_address_as_caller,
        set_contract_address_as_not_caller, pop_and_deserialize_last_event, pop_last_k_events,
        deserialize_event, get_erc20_token, get_replaceable, set_caller_as_upgrade_governor,
        simple_deploy_l2_token, deploy_token_bridge, DEFAULT_UPGRADE_DELAY
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
        let orig = get_contract_address();
        starknet::testing::set_contract_address(contract_address);
        let token_bridge_state = TokenBridge::contract_state_for_testing();
        assert(
            TokenBridge::ReplaceableInternal::is_finalized(@token_bridge_state) == expected,
            'FINALIZED_VALUE_MISMATCH'
        );
        starknet::testing::set_contract_address(orig);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_get_upgrade_delay() {
        _get_upgrade_delay(deploy_token_bridge());
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_get_upgrade_delay() {
        _get_upgrade_delay(simple_deploy_l2_token());
    }

    fn _get_upgrade_delay(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        // Validate the upgrade delay.
        assert(
            replaceable.get_upgrade_delay() == DEFAULT_UPGRADE_DELAY, 'DEFAULT_UPGRADE_DELAY_ERROR'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_add_new_implementation() {
        let replaceable_address = deploy_token_bridge();
        _add_new_implementation(:replaceable_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_add_new_implementation() {
        let replaceable_address = simple_deploy_l2_token();
        _add_new_implementation(:replaceable_address);
    }

    // Perfomrs the add_new_implementation test.
    fn _add_new_implementation(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Check implementation time pre addition.
        assert(
            replaceable.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );
        replaceable.add_new_implementation(:implementation_data);
        assert(
            replaceable.get_impl_activation_time(:implementation_data) == DEFAULT_UPGRADE_DELAY,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: replaceable_address);
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
    fn test_replaceability_bridge_add_new_implementation_not_upgrade_governor() {
        // Deploy the token bridge and continue with the test.
        let replaceable_address = deploy_token_bridge();
        _add_new_impl_not_upg_gov(:replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_add_new_implementation_not_upgrade_governor() {
        // Deploy the ERC20 token and continue with the test.
        let replaceable_address = simple_deploy_l2_token();
        _add_new_impl_not_upg_gov(:replaceable_address);
    }

    // Test impl of trying to add new impl, when not holding upg_gov role.
    fn _add_new_impl_not_upg_gov(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        let not_governor_address = not_caller();
        starknet::testing::set_contract_address(not_governor_address);
        replaceable.add_new_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_remove_implementation() {
        let replaceable_address = deploy_token_bridge();
        _remove_implementation(:replaceable_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_remove_implementation() {
        let replaceable_address = simple_deploy_l2_token();
        _remove_implementation(:replaceable_address);
    }

    fn _remove_implementation(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Remove implementation that was not previously added.
        // TODO the following should NOT emit an event.
        replaceable.remove_implementation(:implementation_data);
        assert(
            replaceable.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Add implementation.
        replaceable.add_new_implementation(:implementation_data);

        // Validate event emission for adding the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: replaceable_address);
        assert(
            emitted_event == Event::ImplementationAdded(
                ImplementationAdded { implementation_data: implementation_data }
            ),
            'ImplementationAdded Error'
        );

        // Remove implementation.
        replaceable.remove_implementation(:implementation_data);

        assert(
            replaceable.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission for removing the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: replaceable_address);
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
    fn test_replaceability_bridge_remove_implementation_not_upgrade_governor() {
        let replaceable_address = deploy_token_bridge();
        _remove_implementation_not_upgrade_governor(:replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_remove_implementation_not_upgrade_governor() {
        let replaceable_address = simple_deploy_l2_token();
        _remove_implementation_not_upgrade_governor(:replaceable_address);
    }

    fn _remove_implementation_not_upgrade_governor(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        replaceable.remove_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_replace_to_with_eic() {
        let replaceable_address = deploy_token_bridge();
        _replace_to_with_eic(:replaceable_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_replace_to_with_eic() {
        let replaceable_address = simple_deploy_l2_token();
        _replace_to_with_eic(:replaceable_address);
    }

    fn _replace_to_with_eic(replaceable_address: ContractAddress) {
        // Tests replacing an implementation to a non-final implementation using EIC, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a dummy implementation replacement with eic
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the eic effect

        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_eic_implementation_data();

        // Add implementation and advance time to enable it.
        replaceable.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        replaceable.replace_to(:implementation_data);
        let updated_upgrade_delay = replaceable.get_upgrade_delay();

        assert(
            updated_upgrade_delay == DEFAULT_UPGRADE_DELAY + EIC_UPGRADE_DELAY_ADDITION,
            'EIC_FAILED'
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_replace_to_nonfinal() {
        let replaceable_address = deploy_token_bridge();
        _replace_to_nonfinal(:replaceable_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_replace_to_nonfinal() {
        let replaceable_address = simple_deploy_l2_token();
        _replace_to_nonfinal(:replaceable_address);
    }

    fn _replace_to_nonfinal(replaceable_address: ContractAddress) {
        // Tests replacing an implementation to a non-final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a non-final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implemenation is not final
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Add implementation and advance time to enable it.
        replaceable.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        replaceable.replace_to(:implementation_data);

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: replaceable_address);
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
    fn test_replaceability_bridge_remove_impl_on_replace() {
        let replaceable_address = deploy_token_bridge();
        _replace_remove_impl_on_replace(:replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_remove_impl_on_replace() {
        let replaceable_address = simple_deploy_l2_token();
        _replace_remove_impl_on_replace(:replaceable_address);
    }

    fn _replace_remove_impl_on_replace(replaceable_address: ContractAddress) {
        // Tests that when replacing class-hash, the impl time is reset to zero.
        // 1. deploys a replaceable contract
        // 2. generates implementation replacement to the same classhash.
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the impl time is now zero.
        // 7. Fails to replace to this impl.
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        // Prepare implementation data with the same class hash (repalce to self).
        let implementation_data = get_dummy_nonfinal_implementation_data();
        let other_implementation_data = get_dummy_final_implementation_data();

        // Add implementations.
        replaceable.add_new_implementation(:implementation_data);
        replaceable.add_new_implementation(implementation_data: other_implementation_data);
        assert(
            replaceable.get_impl_activation_time(:implementation_data) != 0, 'EXPECTED_NON_ZERO'
        );
        assert(
            replaceable
                .get_impl_activation_time(implementation_data: other_implementation_data) != 0,
            'EXPECTED_NON_ZERO'
        );

        // Advance time to enable implementation.
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        replaceable.replace_to(:implementation_data);

        // Check enabled timestamp zerod for repalced to impl, and non-zero for other.
        assert(replaceable.get_impl_activation_time(:implementation_data) == 0, 'EXPECTED_ZERO');
        assert(
            replaceable
                .get_impl_activation_time(implementation_data: other_implementation_data) != 0,
            'EXPECTED_NON_ZERO'
        );

        // Should revert with UNKNOWN_IMPLEMENTATION as replace_to removes the implementation.
        replaceable.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('IMPLEMENTATION_EXPIRED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_expire_impl() {
        // Tests that when impl class-hash cannot be replaced to after expiration.
        _expire_impl(replaceable_address: deploy_token_bridge());
    }

    #[test]
    #[should_panic(expected: ('IMPLEMENTATION_EXPIRED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_expire_impl() {
        // Tests that when impl class-hash cannot be replaced to after expiration.
        _expire_impl(replaceable_address: simple_deploy_l2_token());
    }

    fn _expire_impl(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        // Prepare implementation data with the same class hash (repalce to self).
        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Add implementation.
        replaceable.add_new_implementation(:implementation_data);
        assert(
            replaceable.get_impl_activation_time(:implementation_data) != 0, 'EXPECTED_NON_ZERO'
        );

        // Advance time to enable implementation.
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);
        replaceable.replace_to(:implementation_data);

        // Check enabled timestamp zerod for repalced to impl, and non-zero for other.
        assert(replaceable.get_impl_activation_time(:implementation_data) == 0, 'EXPECTED_ZERO');

        // Add implementation for 2md time.
        replaceable.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(
            DEFAULT_UPGRADE_DELAY + 1 + DEFAULT_UPGRADE_DELAY + 14 * 3600 * 24 + 2
        );

        // Should revert on expired_impl.
        replaceable.replace_to(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_replace_to_final() {
        _replace_to_final(replaceable_address: deploy_token_bridge());
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_replace_to_final() {
        _replace_to_final(replaceable_address: deploy_token_bridge());
    }

    fn _replace_to_final(replaceable_address: ContractAddress) {
        // Tests replacing an implementation to a final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implementation is final

        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_final_implementation_data();

        // Add implementation and advance time to enable it.
        replaceable.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        replaceable.replace_to(:implementation_data);

        // Validate event emissions -- replacement and finalization of the implementation.
        let implementation_events = pop_last_k_events(address: replaceable_address, k: 2);

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
        assert_finalized_status(expected: true, contract_address: replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_replace_to_not_upgrade_governor() {
        _replace_to_not_upgrade_governor(replaceable_address: deploy_token_bridge());
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_replace_to_not_upgrade_governor() {
        _replace_to_not_upgrade_governor(replaceable_address: simple_deploy_l2_token());
    }

    fn _replace_to_not_upgrade_governor(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        let implementation_data = get_dummy_nonfinal_implementation_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        replaceable.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('FINALIZED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_replace_to_already_final() {
        let replaceable_address = deploy_token_bridge();
        _replace_to_already_final(:replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('FINALIZED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_replace_to_already_final() {
        let replaceable_address = simple_deploy_l2_token();
        _replace_to_already_final(:replaceable_address);
    }

    fn _replace_to_already_final(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);
        let implementation_data = get_dummy_final_implementation_data();

        // Set the contract address to be of the token bridge, so we can call the internal
        // finalize() function on the replaceable contract state.
        starknet::testing::set_contract_address(replaceable_address);

        // We use TokenBridge here, as a generic contract that imeplements replaceable.
        // This is due to testing framework limitations. de-facto it can apply on other replaceble
        // contracts as well.
        let mut contract_state = TokenBridge::contract_state_for_testing();
        TokenBridge::ReplaceableInternal::finalize(ref contract_state);

        set_contract_address_as_caller();
        replaceable.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_bridge_unknown_implementation() {
        let replaceable_address = deploy_token_bridge();
        _replace_unknown_implementation(:replaceable_address);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_replaceability_erc20_unknown_implementation() {
        let replaceable_address = simple_deploy_l2_token();
        _replace_unknown_implementation(:replaceable_address);
    }

    fn _replace_unknown_implementation(replaceable_address: ContractAddress) {
        let replaceable = get_replaceable(:replaceable_address);
        set_caller_as_upgrade_governor(:replaceable_address);

        let implementation_data = get_dummy_final_implementation_data();

        // Calling replace_to without previously adding the implementation.
        replaceable.replace_to(:implementation_data);
    }
}
