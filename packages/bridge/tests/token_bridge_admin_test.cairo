//! Integration tests for TokenBridge admin functionality.
//! These tests only use external dispatchers and don't require L1 handler access.

use bridge::interfaces::{ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait};
use starknet::EthAddress;
use super::test_utils::{
    CALLER, NOT_CALLER, deploy_token_bridge, get_default_l1_addresses, get_token_bridge_admin,
    set_caller_as_app_role_admin_app_governor, set_contract_address_as_not_caller,
    stock_erc20_class_hash,
};

// ==================== Helper Functions ====================

fn deploy_and_prepare() -> ITokenBridgeAdminDispatcher {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_app_role_admin_app_governor(:token_bridge_address);
    get_token_bridge_admin(:token_bridge_address)
}

// ==================== Tests ====================

#[test]
fn test_set_l1_bridge() {
    let token_bridge_address = deploy_token_bridge();
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    set_caller_as_app_role_admin_app_governor(:token_bridge_address);

    let (l1_bridge_address, _, _) = get_default_l1_addresses();
    token_bridge_admin.set_l1_bridge(:l1_bridge_address);

    // Verify the l1 bridge was set by checking get_l1_bridge returns it
    assert(token_bridge_admin.get_l1_bridge() == l1_bridge_address, 'L1 bridge not set correctly');
}

#[test]
#[should_panic(expected: ("ONLY_APP_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_missing_role_set_l1_bridge() {
    let token_bridge_admin = deploy_and_prepare();

    let (l1_bridge_address, _, _) = get_default_l1_addresses();
    set_contract_address_as_not_caller();
    token_bridge_admin.set_l1_bridge(:l1_bridge_address);
}

#[test]
#[should_panic(expected: ('L1_BRIDGE_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED'))]
fn test_already_set_l1_bridge() {
    let token_bridge_admin = deploy_and_prepare();

    let (l1_bridge_address, _, _) = get_default_l1_addresses();
    token_bridge_admin.set_l1_bridge(:l1_bridge_address);
    token_bridge_admin.set_l1_bridge(:l1_bridge_address);
}

#[test]
#[should_panic(expected: ('ZERO_L1_BRIDGE_ADDRESS', 'ENTRYPOINT_FAILED'))]
fn test_zero_address_set_l1_bridge() {
    let token_bridge_admin = deploy_and_prepare();

    let zero_address: EthAddress = 0.try_into().unwrap();
    token_bridge_admin.set_l1_bridge(l1_bridge_address: zero_address);
}

#[test]
fn test_set_erc20_class_hash() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_app_role_admin_app_governor(:token_bridge_address);

    let erc20_class_hash = stock_erc20_class_hash();
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    token_bridge_admin.set_erc20_class_hash(:erc20_class_hash);

    assert(token_bridge_admin.get_erc20_class_hash() == erc20_class_hash, 'erc20 mismatch.');
}

#[test]
fn test_set_l2_token_gov() {
    let token_bridge_address = deploy_token_bridge();
    set_caller_as_app_role_admin_app_governor(:token_bridge_address);
    let _caller = CALLER;
    let _not_caller = NOT_CALLER;

    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    token_bridge_admin.set_l2_token_governance(l2_token_governance: _not_caller);

    assert(
        token_bridge_admin.get_l2_token_governance() == _not_caller, 'failed to set l2_token_gov',
    );

    token_bridge_admin.set_l2_token_governance(l2_token_governance: _caller);
    assert(token_bridge_admin.get_l2_token_governance() == _caller, 'failed to set l2_token_gov');
}

#[test]
#[should_panic(expected: ("ONLY_APP_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_missing_role_set_erc20_class_hash() {
    let token_bridge_admin = deploy_and_prepare();

    set_contract_address_as_not_caller();
    token_bridge_admin.set_erc20_class_hash(erc20_class_hash: stock_erc20_class_hash());
}

#[test]
#[should_panic(expected: ("ONLY_APP_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_missing_role_set_l2_token_gov() {
    let token_bridge = deploy_and_prepare();

    set_contract_address_as_not_caller();
    token_bridge.set_l2_token_governance(CALLER);
}

#[test]
#[should_panic(expected: ("ONLY_SECURITY_AGENT", 'ENTRYPOINT_FAILED'))]
fn test_enable_withdrawal_limit_not_security_agent() {
    let token_bridge_address = deploy_token_bridge();
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);

    let (_, l1_token, _) = get_default_l1_addresses();
    token_bridge_admin.enable_withdrawal_limit(:l1_token);
}

#[test]
#[should_panic(expected: ("ONLY_SECURITY_ADMIN", 'ENTRYPOINT_FAILED'))]
fn test_disable_withdrawal_limit_not_security_admin() {
    let token_bridge_address = deploy_token_bridge();
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);

    let (_, l1_token, _) = get_default_l1_addresses();

    set_contract_address_as_not_caller();
    token_bridge_admin.disable_withdrawal_limit(:l1_token);
}
