//! EIP-712 compatible signature utilities using pedersen hashing.
//!
//! This module provides byte-compatible signature verification for lock and delegate
//! operations, following the SNIP equivalent of EIP-712.

use openzeppelin_interfaces::accounts::{AccountABIDispatcher, AccountABIDispatcherTrait};
use starknet::{ContractAddress, get_contract_address, get_tx_info};

// sn_keccak('StarkNetDomain(name:felt,version:felt,chainId:felt,verifyingContract:felt)')
//
// SECURITY: `verifyingContract` is part of the domain so that a signature produced for one
// lockable-token contract cannot be replayed against another contract that imports this
// module (a fork, a testnet clone, or a future redeployment at a different address on the
// same chain). EIP-712 requires the domain to bind the verifying contract for exactly this
// reason. Changing this constant changes every signature hash, so the delegation keeper and
// front-end signer must be updated in lockstep with the contract upgrade.
//
// = sn_keccak('StarkNetDomain(name:felt,version:felt,chainId:felt,verifyingContract:felt)')
pub const STARKNET_DOMAIN_TYPE_HASH: felt252 =
    0xca98cfb7dd7f8905a216be4121e5183d688a00106289a1547b8bc15b38461;

// sn_keccak('LockAndDelegateRequest(delegatee:felt,amount:u256,nonce:felt,expiry:felt)')
//
// SECURITY: `amount` is a `u256` and is committed to in full, as two hashed felts
// (`amount.low` then `amount.high`). The previous type string declared `amount:felt` and the
// hash only covered `amount.low`, which left `amount.high` completely unbound: a signature
// obtained for amount = X also validated for X + k * 2^128, so a captured signature could be
// replayed with an arbitrarily larger amount and `_lock_and_delegate` would approve and
// transfer that larger sum. The type string therefore declares `amount:u256`.
//
// Changing this constant changes every signature hash; it must ship together with an
// updated off-chain signer.
//
// = sn_keccak('LockAndDelegateRequest(delegatee:felt,amount:u256,nonce:felt,expiry:felt)')
pub const LOCK_AND_DELEGATE_TYPE_HASH: felt252 =
    0x34747b0d2887193758ab94a43ee8a024d452a894901af5ca548b220fab47397;

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
///
/// SECURITY: both limbs of the `u256` amount are hashed. Omitting `amount.high` would leave
/// the high 128 bits unbound, so any signature for `amount = X` would also validate for
/// `X + k * 2^128` — see the note on `LOCK_AND_DELEGATE_TYPE_HASH`.
fn lock_and_delegate_input_hash(
    delegatee: ContractAddress, amount: u256, nonce: felt252, expiry: u64,
) -> felt252 {
    let lock_and_delegate_inputs = array![
        LOCK_AND_DELEGATE_TYPE_HASH,
        delegatee.into(),
        amount.low.into(),
        amount.high.into(),
        nonce,
        expiry.into(),
    ]
        .span();
    pedersen_hash_span(lock_and_delegate_inputs)
}

/// Calculates the domain hash for EIP-712.
///
/// The verifying contract address is folded in so signatures are bound to this deployment —
/// see the note on `STARKNET_DOMAIN_TYPE_HASH`.
pub fn calc_domain_hash() -> felt252 {
    let domain_state_inputs = array![
        STARKNET_DOMAIN_TYPE_HASH,
        DAPP_NAME,
        DAPP_VERSION,
        get_tx_info().unbox().chain_id,
        get_contract_address().into(),
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
