//! Test utilities for strk package tests.

use openzeppelin_interfaces::erc20::IERC20Dispatcher;
use openzeppelin_interfaces::governance::votes::IVotesDispatcher;
use starknet::ContractAddress;
use starknet::syscalls::deploy_syscall;
use starkware_utils::components::replaceability::interface::IReplaceableDispatcher;
use starkware_utils::components::roles::interface::{
    IGovernanceRolesDispatcher, IGovernanceRolesDispatcherTrait,
};
use strk::erc20_lockable::ERC20Lockable;
use strk::erc20_votes_lock::ERC20VotesLock;
use strk::interfaces::{
    ILockAndDelegateDispatcher, ILockingContractDispatcher, IMintableLockDispatcher,
    ITokenLockDispatcher,
};

// ==================== Constants ====================

pub const DEFAULT_UPGRADE_DELAY: u64 = 12345;
pub const DECIMALS: u8 = 18;

// ==================== Address Constants ====================

pub const CALLER: ContractAddress = 15.try_into().unwrap();
pub const NOT_CALLER: ContractAddress = 16.try_into().unwrap();
pub const INITIAL_OWNER: ContractAddress = 17.try_into().unwrap();
pub const PERMITTED_MINTER: ContractAddress = 18.try_into().unwrap();
pub const ARBITRARY_ADDRESS: ContractAddress = 3563.try_into().unwrap();
pub const ARBITRARY_USER: ContractAddress = 7171.try_into().unwrap();

pub fn set_contract_address_as_caller() {
    starknet::testing::set_contract_address(CALLER);
}

pub fn set_contract_address_as_not_caller() {
    starknet::testing::set_contract_address(NOT_CALLER);
}

// ==================== Dispatcher Getters ====================

pub fn get_erc20_token(l2_token: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: l2_token }
}

pub fn get_erc20_votes_token(l2_token: ContractAddress) -> IVotesDispatcher {
    IVotesDispatcher { contract_address: l2_token }
}

pub fn get_lock_and_delegate_interface(l2_token: ContractAddress) -> ILockAndDelegateDispatcher {
    ILockAndDelegateDispatcher { contract_address: l2_token }
}

pub fn get_locking_contract_interface(l2_token: ContractAddress) -> ILockingContractDispatcher {
    ILockingContractDispatcher { contract_address: l2_token }
}

pub fn get_token_lock_interface(l2_token: ContractAddress) -> ITokenLockDispatcher {
    ITokenLockDispatcher { contract_address: l2_token }
}

pub fn get_mintable_lock_interface(l2_token: ContractAddress) -> IMintableLockDispatcher {
    IMintableLockDispatcher { contract_address: l2_token }
}

pub fn get_roles(contract_address: ContractAddress) -> IGovernanceRolesDispatcher {
    IGovernanceRolesDispatcher { contract_address }
}

pub fn get_replaceable(replaceable_address: ContractAddress) -> IReplaceableDispatcher {
    IReplaceableDispatcher { contract_address: replaceable_address }
}

// ==================== Deploy Helpers ====================

fn get_lockable_token_deployment_calldata(
    initial_owner: ContractAddress,
    permitted_minter: ContractAddress,
    governance_admin: ContractAddress,
    initial_supply: u256,
) -> Span<felt252> {
    let mut calldata: Array<felt252> = array![];
    let name: ByteArray = "STRK";
    let symbol: ByteArray = "STRK";

    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    DECIMALS.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    initial_owner.serialize(ref calldata);
    permitted_minter.serialize(ref calldata);
    governance_admin.serialize(ref calldata);
    DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
    calldata.span()
}

fn get_votes_lock_deployment_calldata(
    locked_token: ContractAddress, governance_admin: ContractAddress,
) -> Span<felt252> {
    let mut calldata: Array<felt252> = array![];
    let name: ByteArray = "vSTRK";
    let symbol: ByteArray = "vSTRK";

    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    DECIMALS.serialize(ref calldata);
    locked_token.serialize(ref calldata);
    governance_admin.serialize(ref calldata);
    DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
    calldata.span()
}

/// Deploys an ERC20Lockable (STRK) token contract.
pub fn deploy_lockable_token(
    initial_owner: ContractAddress, initial_supply: u256,
) -> ContractAddress {
    let calldata = get_lockable_token_deployment_calldata(
        :initial_owner,
        permitted_minter: PERMITTED_MINTER,
        governance_admin: CALLER,
        :initial_supply,
    );

    // Set the caller address for all function calls (except constructor)
    set_contract_address_as_caller();

    // Deploy the contract using TEST_CLASS_HASH
    let (contract_address, _) = deploy_syscall(
        ERC20Lockable::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false,
    )
        .unwrap();
    contract_address
}

/// Deploys an ERC20VotesLock (vSTRK) token contract.
pub fn deploy_votes_lock(locked_token: ContractAddress) -> ContractAddress {
    let calldata = get_votes_lock_deployment_calldata(
        :locked_token, governance_admin: locked_token,
    );

    // Set the caller address for all function calls (except constructor)
    set_contract_address_as_caller();

    // Deploy the contract using TEST_CLASS_HASH
    let (contract_address, _) = deploy_syscall(
        ERC20VotesLock::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false,
    )
        .unwrap();
    contract_address
}

/// Deploys both lockable and votes lock tokens, returning (lockable, votes_lock).
pub fn deploy_lock_and_votes_tokens(initial_supply: u256) -> (ContractAddress, ContractAddress) {
    let lockable_token = deploy_lockable_token(initial_owner: CALLER, :initial_supply);
    let votes_lock_token = deploy_votes_lock(locked_token: lockable_token);
    (lockable_token, votes_lock_token)
}

/// Deploys both lockable and votes lock tokens with a specific owner.
pub fn deploy_lock_and_votes_tokens_with_owner(
    initial_owner: ContractAddress, initial_supply: u256,
) -> (ContractAddress, ContractAddress) {
    let lockable_token = deploy_lockable_token(:initial_owner, :initial_supply);
    let votes_lock_token = deploy_votes_lock(locked_token: lockable_token);
    (lockable_token, votes_lock_token)
}

/// Simple deployment with default values.
pub fn simple_deploy_lockable_token() -> ContractAddress {
    deploy_lockable_token(initial_owner: INITIAL_OWNER, initial_supply: 1000_u256)
}

// ==================== Role Helpers ====================

pub fn set_caller_as_upgrade_governor(replaceable_address: ContractAddress) {
    let contract_roles = get_roles(contract_address: replaceable_address);
    contract_roles.register_upgrade_governor(account: CALLER);
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

// ==================== TestAccount Contract ====================

/// A lean dummy account that implements `is_valid_signature`.
#[starknet::interface]
pub trait IsValidSignature<TState> {
    fn is_valid_signature(self: @TState, hash: felt252, signature: Array<felt252>) -> felt252;
}

#[starknet::contract]
pub mod TestAccount {
    use core::ecdsa::check_ecdsa_signature;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        public_key: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, _public_key: felt252) {
        self.public_key.write(_public_key);
    }

    #[abi(embed_v0)]
    impl IsValidSignatureImpl of super::IsValidSignature<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            if self._is_valid_signature(:hash, signature: signature.span()) {
                starknet::VALIDATED
            } else {
                0
            }
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _is_valid_signature(
            self: @ContractState, hash: felt252, signature: Span<felt252>,
        ) -> bool {
            let valid_length = signature.len() == 2_u32;
            if valid_length {
                check_ecdsa_signature(
                    message_hash: hash,
                    public_key: self.public_key.read(),
                    signature_r: *signature.at(0_u32),
                    signature_s: *signature.at(1_u32),
                )
            } else {
                false
            }
        }
    }
}

/// Deploys a TestAccount contract with the given public key.
pub fn deploy_account(public_key: felt252) -> ContractAddress {
    let calldata = array![public_key];
    let (account_address, _) = deploy_syscall(
        TestAccount::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false,
    )
        .unwrap();
    account_address
}
