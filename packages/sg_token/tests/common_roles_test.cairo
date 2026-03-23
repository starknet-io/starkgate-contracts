//! Tests that ERC20Mintable exposes ICommonRoles entry points.
//!
//! These tests act as ABI regression guards: if CommonRolesImpl is ever
//! accidentally removed from the contract, the dispatcher calls below will
//! fail with "entry point not found" instead of the expected panics.

use starkware_utils::components::roles::interface::{
    ICommonRolesDispatcher, ICommonRolesDispatcherTrait, IGovernanceRolesDispatcher,
    IGovernanceRolesDispatcherTrait,
};
use super::test_utils::{CALLER, simple_deploy_token};

fn get_common_roles(contract_address: starknet::ContractAddress) -> ICommonRolesDispatcher {
    ICommonRolesDispatcher { contract_address }
}

fn get_governance_roles(contract_address: starknet::ContractAddress) -> IGovernanceRolesDispatcher {
    IGovernanceRolesDispatcher { contract_address }
}

// ==================== ERC20Mintable ====================

/// disable_legacy_role_reclaim is idempotent — fresh contracts already have reclaim
/// disabled, so calling it again from the upgrade governor must succeed.
#[test]
fn test_erc20_mintable_disable_legacy_role_reclaim() {
    let contract_address = simple_deploy_token();
    starknet::testing::set_contract_address(CALLER);
    // CALLER is governance_admin; register as upgrade_governor to satisfy the guard.
    get_governance_roles(contract_address).register_upgrade_governor(account: CALLER);
    get_common_roles(contract_address).disable_legacy_role_reclaim();
}

/// Fresh contracts disable legacy role reclaim in their constructor.  Calling
/// reclaim_legacy_roles must therefore panic with LEGACY_ROLE_RECLAIM_DISABLED.
/// This also proves the entry point is reachable via the dispatcher.
#[test]
#[should_panic(expected: ("LEGACY_ROLE_RECLAIM_DISABLED", 'ENTRYPOINT_FAILED'))]
fn test_erc20_mintable_reclaim_legacy_roles_disabled() {
    let contract_address = simple_deploy_token();
    get_common_roles(contract_address).reclaim_legacy_roles();
}
