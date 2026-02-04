//! EIP-712 compatible signature utilities using pedersen hashing.
//!
//! This module provides byte-compatible signature verification for lock and delegate
//! operations, following the SNIP equivalent of EIP-712.

use openzeppelin_interfaces::accounts::{AccountABIDispatcher, AccountABIDispatcherTrait};
use starknet::{ContractAddress, get_tx_info};

// sn_keccak('StarkNetDomain(name:felt,version:felt,chainId:felt)')
pub const STARKNET_DOMAIN_TYPE_HASH: felt252 =
    0x1bfc207425a47a5dfa1a50a4f5241203f50624ca5fdf5e18755765416b8e288;

// sn_keccak('LockAndDelegateRequest(delegatee:felt,amount:felt,nonce:felt,expiry:felt)')
pub const LOCK_AND_DELEGATE_TYPE_HASH: felt252 =
    0x2ab9656e71e13c39f9f290cc5354d2e50a410992032118a1779539be0e4e75;

pub const DAPP_NAME: felt252 = 'TOKEN_LOCK_AND_DELEGATION';
pub const DAPP_VERSION: felt252 = '1.0.0';
pub const STARKNET_MESSAGE: felt252 = 'StarkNet Message';

/// Validates a signature against an account contract.
pub fn validate_signature(account: ContractAddress, hash: felt252, signature: Array<felt252>) {
    let is_valid_signature_felt = AccountABIDispatcher { contract_address: account }
        .is_valid_signature(:hash, :signature);

    // Check either 'VALID' or True for backwards compatibility.
    let is_valid_signature = is_valid_signature_felt == starknet::VALIDATED
        || is_valid_signature_felt == 1;

    assert(is_valid_signature, 'SIGNATURE_VALIDATION_FAILED');
}

/// Calculates the message hash for signing, following the SNIP equivalent of EIP-712.
pub fn lock_and_delegate_message_hash(
    domain: felt252,
    account: ContractAddress,
    delegatee: ContractAddress,
    amount: u256,
    nonce: felt252,
    expiry: u64,
) -> felt252 {
    let input_hash = lock_and_delegate_input_hash(:delegatee, :amount, :nonce, :expiry);
    let message_inputs = array![STARKNET_MESSAGE, domain, account.into(), input_hash].span();
    pedersen_hash_span(message_inputs)
}

/// Calculates the hash of lock and delegate input parameters.
fn lock_and_delegate_input_hash(
    delegatee: ContractAddress, amount: u256, nonce: felt252, expiry: u64,
) -> felt252 {
    let lock_and_delegate_inputs = array![
        LOCK_AND_DELEGATE_TYPE_HASH, delegatee.into(), amount.low.into(), nonce, expiry.into(),
    ]
        .span();
    pedersen_hash_span(lock_and_delegate_inputs)
}

/// Calculates the domain hash for EIP-712.
pub fn calc_domain_hash() -> felt252 {
    let domain_state_inputs = array![
        STARKNET_DOMAIN_TYPE_HASH, DAPP_NAME, DAPP_VERSION, get_tx_info().unbox().chain_id,
    ]
        .span();
    pedersen_hash_span(domain_state_inputs)
}

/// Pedersen hash of a span of elements, following the standard format.
pub fn pedersen_hash_span(mut elements: Span<felt252>) -> felt252 {
    let number_of_elements = elements.len();
    assert(number_of_elements > 0, 'Requires at least one element');

    // Pad with 0.
    let mut current: felt252 = 0;
    loop {
        match elements.pop_front() {
            Option::Some(next) => { current = core::pedersen::pedersen(current, *next); },
            Option::None => { break; },
        };
    }
    // Hash with number of elements.
    core::pedersen::pedersen(current, number_of_elements.into())
}
