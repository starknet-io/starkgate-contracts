//! Tests that ERC20Lockable and ERC20VotesLock expose ICommonRoles entry points.
//!
//! These tests act as ABI regression guards: if CommonRolesImpl is ever
//! accidentally removed from a contract, the dispatcher calls below will
//! fail with "entry point not found" instead of the expected panics.

use starkware_utils::components::roles::interface::{
    ICommonRolesDispatcher, ICommonRolesDispatcherTrait,
};
use super::test_utils::{
    deploy_lock_and_votes_tokens, set_caller_as_upgrade_governor, set_contract_address_as_caller,
    simple_deploy_lockable_token,
};

fn get_common_roles(contract_address: starknet::ContractAddress) -> ICommonRolesDispatcher {
    ICommonRolesDispatcher { contract_address }
}

// ==================== ERC20Lockable ====================

/// disable_legacy_role_reclaim is idempotent — fresh contracts already have reclaim
/// disabled, so calling it again from the upgrade governor must succeed.
#[test]
fn test_erc20_lockable_disable_legacy_role_reclaim() {
    let contract_address = simple_deploy_lockable_token();
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
fn test_erc20_lockable_reclaim_legacy_roles_disabled() {
    let contract_address = simple_deploy_lockable_token();
    get_common_roles(contract_address).reclaim_legacy_roles();
}

// ==================== ERC20VotesLock ====================

/// disable_legacy_role_reclaim is idempotent — fresh contracts already have reclaim
/// disabled, so calling it again from the upgrade governor must succeed.
#[test]
fn test_erc20_votes_lock_disable_legacy_role_reclaim() {
    let (lockable, votes_lock) = deploy_lock_and_votes_tokens(initial_supply: 1000_u256);
    // votes_lock uses lockable as its governance_admin — act as lockable to register CALLER
    // as upgrade_governor on votes_lock.
    starknet::testing::set_contract_address(lockable);
    set_caller_as_upgrade_governor(votes_lock);
    // Now act as CALLER (who now holds UPGRADE_GOVERNOR) to call disable_legacy_role_reclaim.
    set_contract_address_as_caller();
    get_common_roles(votes_lock).disable_legacy_role_reclaim();
}

/// Fresh contracts disable legacy role reclaim in their constructor.  Calling
/// reclaim_legacy_roles must therefore panic with LEGACY_ROLE_RECLAIM_DISABLED.
/// This also proves the entry point is reachable via the dispatcher.
#[test]
#[should_panic(expected: ("LEGACY_ROLE_RECLAIM_DISABLED", 'ENTRYPOINT_FAILED'))]
fn test_erc20_votes_lock_reclaim_legacy_roles_disabled() {
    let (_lockable, votes_lock) = deploy_lock_and_votes_tokens(initial_supply: 0_u256);
    get_common_roles(votes_lock).reclaim_legacy_roles();
}
