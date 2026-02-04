//! Integration tests for TokenBridge replaceability functionality.
//! Tests the external replaceability API using dispatchers.

use bridge::token_bridge::TokenBridge;
use starknet::{ClassHash, get_block_timestamp};
use starkware_utils::components::replaceability::interface::{
    IReplaceableDispatcherTrait, ImplementationData,
};
use super::test_utils::{
    DEFAULT_UPGRADE_DELAY, deploy_token_bridge, get_replaceable, set_caller_as_upgrade_governor,
    set_contract_address_as_not_caller,
};

// ==================== Helper Functions ====================

fn get_token_bridge_class_hash() -> ClassHash {
    TokenBridge::TEST_CLASS_HASH.try_into().unwrap()
}

fn dummy_implementation_data(final: bool) -> ImplementationData {
    ImplementationData {
        impl_hash: get_token_bridge_class_hash(), eic_data: Option::None(()), final,
    }
}

// ==================== Tests ====================

#[test]
fn test_add_new_implementation() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    replaceable.add_new_implementation(:implementation_data);

    // Verify the implementation time is set (non-zero means it's added)
    let impl_time = replaceable.get_impl_activation_time(:implementation_data);
    assert(impl_time > 0, 'Implementation not added');
}

#[test]
#[should_panic(expected: ("ONLY_UPGRADE_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_add_new_implementation_not_upgrade_governor() {
    let token_bridge_address = deploy_token_bridge();
    set_contract_address_as_not_caller();

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    replaceable.add_new_implementation(:implementation_data);
}

#[test]
fn test_remove_implementation() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    // First add the implementation
    replaceable.add_new_implementation(:implementation_data);
    let impl_time_before = replaceable.get_impl_activation_time(:implementation_data);
    assert(impl_time_before > 0, 'Implementation not added');

    // Then remove it
    replaceable.remove_implementation(:implementation_data);
    let impl_time_after = replaceable.get_impl_activation_time(:implementation_data);
    assert(impl_time_after == 0, 'Implementation not removed');
}

#[test]
#[should_panic(expected: ("ONLY_UPGRADE_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_remove_implementation_not_upgrade_governor() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    // Add implementation as upgrade governor
    replaceable.add_new_implementation(:implementation_data);

    // Try to remove as non-governor
    set_contract_address_as_not_caller();
    replaceable.remove_implementation(:implementation_data);
}

#[test]
fn test_replace_to_after_delay() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    // Add the implementation
    replaceable.add_new_implementation(:implementation_data);

    // Advance time past the upgrade delay
    let current_time = get_block_timestamp();
    starknet::testing::set_block_timestamp(current_time + DEFAULT_UPGRADE_DELAY + 1);

    // Replace to the new implementation
    replaceable.replace_to(:implementation_data);

    // Verify the implementation is active (time reset to 0 after successful replace)
    let impl_time = replaceable.get_impl_activation_time(:implementation_data);
    assert(impl_time == 0, 'Implementation not activated');
}

#[test]
#[should_panic(expected: ("NOT_ENABLED_YET", 'ENTRYPOINT_FAILED'))]
fn test_replace_to_before_delay() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    // Add the implementation
    replaceable.add_new_implementation(:implementation_data);

    // Try to replace immediately (before delay expires)
    replaceable.replace_to(:implementation_data);
}

#[test]
#[should_panic(expected: ("ONLY_UPGRADER", 'ENTRYPOINT_FAILED'))]
fn test_replace_to_not_upgrade_governor() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_upgrade_governor(replaceable_address: token_bridge_address);

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let implementation_data = dummy_implementation_data(final: false);

    // Add implementation as upgrade governor
    replaceable.add_new_implementation(:implementation_data);

    // Advance time past the upgrade delay
    let current_time = get_block_timestamp();
    starknet::testing::set_block_timestamp(current_time + DEFAULT_UPGRADE_DELAY + 1);

    // Try to replace as non-governor
    set_contract_address_as_not_caller();
    replaceable.replace_to(:implementation_data);
}

#[test]
fn test_get_upgrade_delay() {
    let token_bridge_address = deploy_token_bridge();

    let replaceable = get_replaceable(replaceable_address: token_bridge_address);
    let delay = replaceable.get_upgrade_delay();

    assert(delay == DEFAULT_UPGRADE_DELAY, 'Wrong upgrade delay');
}
