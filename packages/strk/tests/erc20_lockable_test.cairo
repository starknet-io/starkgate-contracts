//! Tests for the ERC20Lockable contract (STRK).

use core::num::traits::Bounded;
use openzeppelin_interfaces::erc20::IERC20DispatcherTrait;
use openzeppelin_interfaces::governance::votes::IVotesDispatcherTrait;
use starknet::ContractAddress;
use strk::eip712_utils::{calc_domain_hash, lock_and_delegate_message_hash};
use strk::interfaces::{ILockAndDelegateDispatcherTrait, ILockingContractDispatcherTrait};
use super::test_utils::{
    ARBITRARY_ADDRESS, ARBITRARY_USER, CALLER, INITIAL_OWNER, NOT_CALLER, deploy_account,
    deploy_lock_and_votes_tokens, deploy_lock_and_votes_tokens_with_owner, deploy_lockable_token,
    get_erc20_token, get_erc20_votes_token, get_lock_and_delegate_interface,
    get_locking_contract_interface, set_caller_as_upgrade_governor,
};

// The account address is taken into account in eip-712 signature.
// So, if it changes, signature fixtures are invalidated and have to be replaced.
// This fixture helps identifying this right away.
fn expected_account_address() -> ContractAddress {
    0x1bccced231c434e2c7a23e5278205ccbee02a516c10c49d696605fefb839f99.try_into().unwrap()
}

fn deploy_testing_lockable_token() -> ContractAddress {
    let initial_owner = INITIAL_OWNER;
    deploy_lockable_token(:initial_owner, initial_supply: 1000_u256)
}

fn set_locking_contract(lockable_token: ContractAddress, locking_contract: ContractAddress) {
    let locking_contract_interface = get_locking_contract_interface(l2_token: lockable_token);
    locking_contract_interface.set_locking_contract(:locking_contract);
}

// Sets the caller as the upgrade governor and then set the locking contract.
fn prepare_and_set_locking_contract(
    lockable_token: ContractAddress, locking_contract: ContractAddress,
) {
    set_caller_as_upgrade_governor(replaceable_address: lockable_token);
    set_locking_contract(:lockable_token, :locking_contract);
}

fn lock_and_delegate(lockable_token: ContractAddress, delegatee: ContractAddress, amount: u256) {
    let lock_and_delegate_interface = get_lock_and_delegate_interface(l2_token: lockable_token);
    lock_and_delegate_interface.lock_and_delegate(:delegatee, :amount);
}

fn lock_and_delegate_by_sig(
    lockable_token: ContractAddress,
    account: ContractAddress,
    delegatee: ContractAddress,
    amount: u256,
    nonce: felt252,
    expiry: u64,
    signature: Array<felt252>,
) {
    let lock_and_delegate_interface = get_lock_and_delegate_interface(l2_token: lockable_token);
    lock_and_delegate_interface
        .lock_and_delegate_by_sig(:account, :delegatee, :amount, :nonce, :expiry, :signature);
}

#[test]
fn test_deploy_lockable_token() {
    deploy_testing_lockable_token();
}

#[test]
#[should_panic(expected: ("ONLY_UPGRADE_GOVERNOR", 'ENTRYPOINT_FAILED'))]
fn test_failed_set_locking_contract_not_upgrade_governor() {
    let lockable_token = deploy_testing_lockable_token();
    set_locking_contract(:lockable_token, locking_contract: ARBITRARY_ADDRESS);
}

#[test]
#[should_panic(expected: ('ZERO_ADDRESS', 'ENTRYPOINT_FAILED'))]
fn test_failed_set_locking_contract_zero_address() {
    let lockable_token = deploy_testing_lockable_token();
    let zero_locking_contract_address = 0.try_into().unwrap();
    prepare_and_set_locking_contract(
        :lockable_token, locking_contract: zero_locking_contract_address,
    );
}

#[test]
#[should_panic(expected: ('LOCKING_CONTRACT_ALREADY_SET', 'ENTRYPOINT_FAILED'))]
fn test_failed_set_locking_contract_already_set() {
    let lockable_token = deploy_testing_lockable_token();

    prepare_and_set_locking_contract(:lockable_token, locking_contract: ARBITRARY_ADDRESS);
    let another_locking_contract_address: ContractAddress = 20.try_into().unwrap();
    set_locking_contract(:lockable_token, locking_contract: another_locking_contract_address);
}

#[test]
fn test_set_and_get_locking_contact() {
    let lockable_token = deploy_testing_lockable_token();

    set_caller_as_upgrade_governor(replaceable_address: lockable_token);
    let locking_contract_interface = get_locking_contract_interface(l2_token: lockable_token);
    locking_contract_interface.set_locking_contract(locking_contract: ARBITRARY_ADDRESS);
    let locking_contract_result = locking_contract_interface.get_locking_contract();
    assert(locking_contract_result == ARBITRARY_ADDRESS, 'UNEXPECTED_LOCKING_CONTRACT');
}

#[test]
#[should_panic(expected: ('LOCKING_CONTRACT_NOT_SET', 'ENTRYPOINT_FAILED'))]
fn test_failed_lock_and_delegate_not_set() {
    let lockable_token = deploy_testing_lockable_token();
    let delegatee = ARBITRARY_USER;
    lock_and_delegate(:lockable_token, :delegatee, amount: 100_u256);
}

#[test]
fn test_happy_flow_lock_and_delegate() {
    let initial_supply = 1000_u256;
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

    // Store votes_lock_token as the locking contract.
    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    let erc20_lockable_interface = get_erc20_token(l2_token: lockable_token);
    let erc20_votes_lock_interface = get_erc20_token(l2_token: votes_lock_token);

    // Verify that the caller has balance of initial_supply for the locked token and zero
    // balance of the votes token.
    assert(
        erc20_lockable_interface.balance_of(account: CALLER) == initial_supply,
        'BAD_BALANCE_TEST_SETUP',
    );
    assert(erc20_votes_lock_interface.balance_of(account: CALLER) == 0, 'BAD_BALANCE_TEST_SETUP');

    let delegatee = ARBITRARY_USER;
    lock_and_delegate(:lockable_token, :delegatee, amount: initial_supply);

    // Verify that the caller has balance of initial_supply for the votes token and zero balance
    // of the locked token.
    assert(erc20_lockable_interface.balance_of(account: CALLER) == 0, 'UNEXPECTED_BALANCE');
    assert(
        erc20_votes_lock_interface.balance_of(account: CALLER) == initial_supply,
        'UNEXPECTED_BALANCE',
    );
    // Verify that the votes_lock_token has balance of initial_supply for the locked token.
    assert(
        erc20_lockable_interface.balance_of(account: votes_lock_token) == initial_supply,
        'UNEXPECTED_BALANCE',
    );

    let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
    assert(erc20_votes_token_interface.delegates(account: CALLER) == delegatee, 'DELEGATE_FAILED');
}

#[test]
#[should_panic(
    expected: (
        'ERC20: insufficient balance',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
    ),
)]
fn test_lock_and_delegate_underflow() {
    let initial_supply = 1000_u256;
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

    // Store votes_lock_token as the locking contract.
    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Caller try to delegate more than his supply.
    let delegatee = ARBITRARY_USER;
    lock_and_delegate(:lockable_token, :delegatee, amount: initial_supply + 1);
}

// Tests that the lock_and_delegate function can handle Bounded::MAX.
#[test]
fn test_lock_and_delegate_max_bounded_int() {
    let initial_supply = Bounded::MAX;
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

    // Store votes_lock_token as the locking contract.
    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Caller try to delegate all his balance which is Bounded::MAX.
    let delegatee = ARBITRARY_USER;
    lock_and_delegate(:lockable_token, :delegatee, amount: Bounded::MAX);
}

fn get_initial_supply() -> u256 {
    1000_u256
}

// Significant other of the number 0x52656d6f20746865206d657263696c657373 .
fn get_account_public_key() -> felt252 {
    0x890324441c151f11fc60046f5db3014faf0e7ec427797bead23e279e0604a2
}

fn get_delegation_sig() -> Array<felt252> {
    array![
        0x3ce38432f2c30ccbd15f147d4ea31e2e849ba7516a4020b979bfd959f466d40,
        0x507b4f61db2bbd3156ac4f2061231fc784ea60e5e3038e60e41f3950360b41b,
    ]
}

const DELEGATEE: ContractAddress = 10.try_into().unwrap();
const EXPIRY: u64 = 123456_u64;
const NONCE: felt252 = 32;
const CHAIN_ID: felt252 = 'SN_GOERLI';

// NOTE: This test uses pre-computed signature fixtures that depend on a specific account address.
// The account address is determined by the class hash of TestAccount, which changes when the
// contract is recompiled. If the signature fixtures need to be regenerated, use
// test_generate_message_hash_for_signature to get the new expected values.
#[test]
fn test_happy_flow_lock_and_delegate_by_sig() {
    // Set chain id.
    starknet::testing::set_chain_id(chain_id: CHAIN_ID);

    // Account setup.
    let account_address = deploy_account(public_key: get_account_public_key());

    // The signature is dependent on the address.
    // If it's not the expected address, signature validation will fail.
    assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

    // Lockable token contract setup.
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
        initial_owner: account_address, initial_supply: get_initial_supply(),
    );

    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Set as not caller, to validate caller address isn't improperly used.
    starknet::testing::set_caller_address(address: NOT_CALLER);

    lock_and_delegate_by_sig(
        :lockable_token,
        account: account_address,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE,
        expiry: EXPIRY,
        signature: get_delegation_sig(),
    );

    // Validate delegation success.
    let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
    assert(
        erc20_votes_token_interface.delegates(account: account_address) == DELEGATEE,
        'DELEGATE_FAILED',
    );
}

#[test]
#[should_panic(expected: ('SIGNATURE_EXPIRED', 'ENTRYPOINT_FAILED'))]
fn test_lock_and_delegate_by_sig_expired() {
    starknet::testing::set_block_timestamp(EXPIRY + 1);

    // Lockable token contract setup.
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
        initial_supply: get_initial_supply(),
    );

    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Invoke delegation with signature.
    lock_and_delegate_by_sig(
        :lockable_token,
        account: CALLER,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE,
        expiry: EXPIRY,
        signature: get_delegation_sig(),
    );
}

// NOTE: This test requires regenerated signature fixtures (see
// test_happy_flow_lock_and_delegate_by_sig).
#[test]
#[should_panic(expected: ('SIGNED_REQUEST_ALREADY_USED', 'ENTRYPOINT_FAILED'))]
fn test_lock_and_delegate_by_sig_request_replay() {
    // Set chain id.
    starknet::testing::set_chain_id(chain_id: CHAIN_ID);

    // Account setup.
    let account_address = deploy_account(public_key: get_account_public_key());

    // The signature is dependent on the address.
    // If it's not the expected address, signature validation will fail.
    assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

    // Lockable token contract setup.
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
        initial_owner: account_address, initial_supply: get_initial_supply(),
    );

    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Invoke delegation with signature.
    lock_and_delegate_by_sig(
        :lockable_token,
        account: account_address,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE,
        expiry: 123456,
        signature: get_delegation_sig(),
    );

    // Invoke delegation with signature again.
    lock_and_delegate_by_sig(
        :lockable_token,
        account: account_address,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE,
        expiry: EXPIRY,
        signature: get_delegation_sig(),
    );
}

// NOTE: This test requires regenerated signature fixtures (see
// test_happy_flow_lock_and_delegate_by_sig).
#[test]
#[should_panic(expected: ('SIGNATURE_VALIDATION_FAILED', 'ENTRYPOINT_FAILED'))]
fn test_lock_and_delegate_by_sig_invalid_sig() {
    // Set chain id.
    starknet::testing::set_chain_id(chain_id: CHAIN_ID);

    // Account setup.
    let account_address = deploy_account(public_key: get_account_public_key());

    // The signature is dependent on the address.
    // If it's not the expected address, signature validation will fail.
    // look at `test_generate_message_hash_for_signature` for new account and hashes.
    assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

    // Lockable token contract setup.
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
        initial_owner: account_address, initial_supply: get_initial_supply(),
    );

    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Set as not caller, to validate caller address isn't improperly used.
    starknet::testing::set_caller_address(address: NOT_CALLER);

    // Invoke delegation with signature with modified data that invalidates the signature.
    lock_and_delegate_by_sig(
        :lockable_token,
        account: account_address,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE + 1,
        expiry: EXPIRY,
        signature: get_delegation_sig(),
    );
}

// This test is a helper for generating message hashes when signature fixtures need to be updated.
// It outputs the account address and message hash by panicking with them (since cairo-test doesn't
// have print output). Use the panicked values to generate new signatures with the private key.
#[test]
fn test_generate_message_hash_for_signature() {
    // Set chain id.
    starknet::testing::set_chain_id(chain_id: CHAIN_ID);

    // Account setup.
    let account_address = deploy_account(public_key: get_account_public_key());

    // Lockable token contract setup.
    let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
        initial_owner: account_address, initial_supply: get_initial_supply(),
    );

    prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

    // Set as not caller, to validate caller address isn't improperly used.
    starknet::testing::set_caller_address(address: NOT_CALLER);

    // Calculate the message hash for the deployed account address.
    let hash = lock_and_delegate_message_hash(
        domain: calc_domain_hash(),
        account: account_address,
        delegatee: DELEGATEE,
        amount: get_initial_supply(),
        nonce: NONCE,
        expiry: EXPIRY,
    );

    // Verify the hash is non-zero (basic sanity check).
    assert(hash != 0, 'HASH_IS_ZERO');

    // Check if the account address matches the expected fixture.
    // If not, output the new values via panic for fixture regeneration.
    // let account_felt: felt252 = account_address.into();
    if account_address != expected_account_address() {
        // Output the new account address and hash for fixture generation.
        // To generate new signatures, use the private key corresponding to get_account_public_key()
        // (private key: 0x52656d6f20746865206d657263696c657373) to sign the hash value.
        panic!("NEW_ACCOUNT_ADDRESS: 0x{:x}, MESSAGE_HASH: 0x{:x}", account_address, hash);
    }
}
