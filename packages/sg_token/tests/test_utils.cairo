//! Test utilities for sg_token package tests.

use openzeppelin_interfaces::erc20::IERC20Dispatcher;
use sg_token::erc20_mintable::ERC20Mintable;
use starknet::ContractAddress;
use starknet::syscalls::deploy_syscall;
use starkware_utils::interfaces::mintable_token::IMintableTokenDispatcher;

// Constants
pub const DEFAULT_UPGRADE_DELAY: u64 = 12345;
pub const DECIMALS: u8 = 18;

// ByteArray constants must be functions in Cairo
pub fn NAME() -> ByteArray {
    "TestToken"
}

pub fn SYMBOL() -> ByteArray {
    "TT"
}

// Address constants
pub const CALLER: ContractAddress = 15.try_into().unwrap();
pub const INITIAL_OWNER: ContractAddress = 17.try_into().unwrap();
pub const PERMITTED_MINTER: ContractAddress = 18.try_into().unwrap();
pub const ARBITRARY_USER: ContractAddress = 7171.try_into().unwrap();

fn set_contract_address_as_caller() {
    starknet::testing::set_contract_address(CALLER);
}

// Dispatcher getters
pub fn get_erc20_token(contract_address: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address }
}

pub fn get_mintable_token(contract_address: ContractAddress) -> IMintableTokenDispatcher {
    IMintableTokenDispatcher { contract_address }
}

// Deployment helpers

fn get_l2_token_deployment_calldata(
    initial_owner: ContractAddress,
    permitted_minter: ContractAddress,
    governance_admin: ContractAddress,
    initial_supply: u256,
) -> Span<felt252> {
    let mut calldata: Array<felt252> = array![];
    NAME().serialize(ref calldata);
    SYMBOL().serialize(ref calldata);
    DECIMALS.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    initial_owner.serialize(ref calldata);
    permitted_minter.serialize(ref calldata);
    governance_admin.serialize(ref calldata);
    DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
    calldata.span()
}

/// Deploys an ERC20Mintable contract with the given parameters.
pub fn deploy_mintable_token(
    initial_owner: ContractAddress,
    permitted_minter: ContractAddress,
    initial_supply: u256,
    governance_admin: ContractAddress,
) -> ContractAddress {
    let calldata = get_l2_token_deployment_calldata(
        :initial_owner, :permitted_minter, :governance_admin, :initial_supply,
    );

    // Set the caller address for all function calls (except constructor)
    set_contract_address_as_caller();

    // Deploy the contract using TEST_CLASS_HASH
    let (contract_address, _) = deploy_syscall(
        ERC20Mintable::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false,
    )
        .unwrap();
    contract_address
}

/// Simple deployment helper with default governance admin.
pub fn deploy_l2_token(
    initial_owner: ContractAddress, permitted_minter: ContractAddress, initial_supply: u256,
) -> ContractAddress {
    deploy_mintable_token(
        :initial_owner, :permitted_minter, :initial_supply, governance_admin: CALLER,
    )
}

/// Simple deployment with default values.
pub fn simple_deploy_token() -> ContractAddress {
    deploy_l2_token(
        initial_owner: INITIAL_OWNER, permitted_minter: PERMITTED_MINTER, initial_supply: 1000_u256,
    )
}
