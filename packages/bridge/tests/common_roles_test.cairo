//! Tests that TokenBridge exposes ICommonRoles entry points.
//!
//! These tests act as ABI regression guards: if CommonRolesImpl is ever
//! accidentally removed from the contract, the dispatcher calls below will
//! fail with "entry point not found" instead of the expected panics.

use starkware_utils::components::roles::interface::{
    ICommonRolesDispatcher, ICommonRolesDispatcherTrait,
};
use super::test_utils::{
    deploy_token_bridge, set_caller_as_upgrade_governor, set_contract_address_as_caller,
};

fn get_common_roles(contract_address: starknet::ContractAddress) -> ICommonRolesDispatcher {
    ICommonRolesDispatcher { contract_address }
}

// ==================== TokenBridge ====================

/// disable_legacy_role_reclaim is idempotent — fresh contracts already have reclaim
/// disabled, so calling it again from the upgrade governor must succeed.
#[test]
fn test_token_bridge_disable_legacy_role_reclaim() {
    let contract_address = deploy_token_bridge();
    set_contract_address_as_caller();
    // CALLER is governance_admin; register as upgrade_governor to satisfy the guard.
    set_caller_as_upgrade_governor(contract_address);
    get_common_roles(contract_address).disable_legacy_role_reclaim();
}

/// Fresh contracts disable legacy role reclaim in their constructor.  Calling
/// reclaim_legacy_roles must therefore panic with LEGACY_ROLE_RECLAIM_DISABLED.
/// This also proves the entry point is reachable via the dispatcher.
#[test]
#[should_panic(expected: ("LEGACY_ROLE_RECLAIM_DISABLED", 'ENTRYPOINT_FAILED'))]
fn test_token_bridge_reclaim_legacy_roles_disabled() {
    let contract_address = deploy_token_bridge();
    get_common_roles(contract_address).reclaim_legacy_roles();
}
