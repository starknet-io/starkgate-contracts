//! Test utilities for bridge package integration tests.
//!
//! NOTE: L1 handler tests are now in unit tests inside the TokenBridge contract module.
//! These utilities are for integration tests that use dispatchers only.

use bridge::interfaces::{
    ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait, ITokenBridgeDispatcher,
};
use bridge::token_bridge::TokenBridge;
use openzeppelin_interfaces::erc20::IERC20Dispatcher;
use sg_token::erc20_mintable::ERC20Mintable;
use starknet::syscalls::deploy_syscall;
use starknet::{ClassHash, ContractAddress, EthAddress, get_contract_address};
use starkware_utils::components::replaceability::interface::IReplaceableDispatcher;
use starkware_utils::components::roles::interface::{IRolesDispatcher, IRolesDispatcherTrait};
use starkware_utils::interfaces::mintable_token::IMintableTokenDispatcher;

// ==================== Constants ====================

pub const DEFAULT_UPGRADE_DELAY: u64 = 12345;
pub const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
pub const DEFAULT_L1_RECIPIENT: felt252 = 12;
pub const DEFAULT_L1_TOKEN_ETH_ADDRESS: felt252 = 1337;

pub const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
pub const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;

// ==================== Address Constants ====================

pub const CALLER: ContractAddress = 15.try_into().unwrap();
pub const NOT_CALLER: ContractAddress = 16.try_into().unwrap();
pub const INITIAL_OWNER: ContractAddress = 17.try_into().unwrap();
pub const PERMITTED_MINTER: ContractAddress = 18.try_into().unwrap();

pub fn set_contract_address_as_caller() {
    starknet::testing::set_contract_address(CALLER);
}

pub fn set_contract_address_as_not_caller() {
    starknet::testing::set_contract_address(NOT_CALLER);
}

// ==================== Dispatcher Getters ====================

pub fn get_token_bridge(token_bridge_address: ContractAddress) -> ITokenBridgeDispatcher {
    ITokenBridgeDispatcher { contract_address: token_bridge_address }
}

pub fn get_token_bridge_admin(
    token_bridge_address: ContractAddress,
) -> ITokenBridgeAdminDispatcher {
    ITokenBridgeAdminDispatcher { contract_address: token_bridge_address }
}

pub fn get_roles(contract_address: ContractAddress) -> IRolesDispatcher {
    IRolesDispatcher { contract_address }
}

pub fn get_replaceable(replaceable_address: ContractAddress) -> IReplaceableDispatcher {
    IReplaceableDispatcher { contract_address: replaceable_address }
}

pub fn get_erc20_token(l2_token: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: l2_token }
}

pub fn get_mintable_token(l2_token: ContractAddress) -> IMintableTokenDispatcher {
    IMintableTokenDispatcher { contract_address: l2_token }
}

// ==================== Default Helpers ====================

pub const DEFAULT_AMOUNT: u256 = u256 {
    low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH,
};

pub fn get_l1_bridge_address() -> EthAddress {
    DEFAULT_L1_BRIDGE_ETH_ADDRESS.try_into().unwrap()
}

pub fn get_l1_token_address() -> EthAddress {
    DEFAULT_L1_TOKEN_ETH_ADDRESS.try_into().unwrap()
}

pub fn get_l1_recipient() -> EthAddress {
    DEFAULT_L1_RECIPIENT.try_into().unwrap()
}

pub fn get_default_l1_addresses() -> (EthAddress, EthAddress, EthAddress) {
    (get_l1_bridge_address(), get_l1_token_address(), get_l1_recipient())
}

// ==================== Class Hash Helpers ====================

pub fn stock_erc20_class_hash() -> ClassHash {
    ERC20Mintable::TEST_CLASS_HASH.try_into().unwrap()
}

// ==================== Deploy Helpers ====================

/// Deploys the TokenBridge contract.
pub fn deploy_token_bridge() -> ContractAddress {
    let mut calldata: Array<felt252> = array![];
    let _caller = CALLER;
    _caller.serialize(ref calldata);
    DEFAULT_UPGRADE_DELAY.serialize(ref calldata);

    set_contract_address_as_caller();
    starknet::testing::set_caller_address(CALLER);

    let (token_bridge_address, _) = deploy_syscall(
        TokenBridge::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false,
    )
        .unwrap();
    token_bridge_address
}

// ==================== Role Helpers ====================

pub fn set_caller_as_upgrade_governor(replaceable_address: ContractAddress) {
    let contract_roles = get_roles(contract_address: replaceable_address);
    contract_roles.register_upgrade_governor(account: CALLER);
}

pub fn set_caller_as_app_role_admin_app_governor(token_bridge_address: ContractAddress) {
    let token_bridge_roles = get_roles(contract_address: token_bridge_address);
    token_bridge_roles.register_app_role_admin(account: CALLER);
    token_bridge_roles.register_app_governor(account: CALLER);
}

pub fn set_caller_as_security_admin(token_bridge_address: ContractAddress) {
    let token_bridge_roles = get_roles(contract_address: token_bridge_address);
    token_bridge_roles.register_security_admin(account: CALLER);
}

pub fn set_caller_as_security_agent(token_bridge_address: ContractAddress) {
    let token_bridge_roles = get_roles(contract_address: token_bridge_address);
    token_bridge_roles.register_security_agent(account: CALLER);
}

// ==================== Bridge Setup Helpers ====================

/// Prepares the bridge with L1 bridge address and ERC20 class hash set.
pub fn prepare_bridge_for_deploy_token(
    token_bridge_address: ContractAddress, l1_bridge_address: EthAddress,
) {
    let orig = get_contract_address();

    set_contract_address_as_caller();
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    set_caller_as_app_role_admin_app_governor(:token_bridge_address);

    token_bridge_admin.set_l1_bridge(:l1_bridge_address);
    token_bridge_admin.set_erc20_class_hash(erc20_class_hash: stock_erc20_class_hash());
    token_bridge_admin.set_l2_token_governance(l2_token_governance: CALLER);

    starknet::testing::set_contract_address(orig);
}

pub fn enable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
    set_contract_address_as_caller();
    set_caller_as_security_agent(:token_bridge_address);
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    token_bridge_admin.enable_withdrawal_limit(:l1_token);
}

pub fn disable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
    set_contract_address_as_caller();
    set_caller_as_security_admin(:token_bridge_address);
    let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
    token_bridge_admin.disable_withdrawal_limit(:l1_token);
}

// ==================== Event Helpers ====================

/// Returns the last event in the queue. After this call, the event queue is empty.
pub fn pop_and_deserialize_last_event<T, +starknet::Event<T>, +Drop<T>>(
    address: ContractAddress,
) -> T {
    let mut prev_log = starknet::testing::pop_log_raw(:address).expect('Event queue is empty.');
    loop {
        match starknet::testing::pop_log_raw(:address) {
            Option::Some(log) => { prev_log = log; },
            Option::None(()) => { break; },
        };
    }
    deserialize_event(raw_event: prev_log)
}

/// Deserializes a raw event into the specified type.
pub fn deserialize_event<T, +starknet::Event<T>>(
    mut raw_event: (Span::<felt252>, Span::<felt252>),
) -> T {
    let (mut keys, mut data) = raw_event;
    starknet::Event::deserialize(ref keys, ref data).expect('Event deserializion failed')
}
