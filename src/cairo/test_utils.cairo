use array::ArrayTrait;
use core::result::ResultTrait;
use traits::TryInto;
use option::OptionTrait;
use serde::Serde;
use starknet::{ContractAddress, syscalls::deploy_syscall};
use super::permissioned_erc20::PermissionedERC20;
use super::mintable_token_interface::{IMintableTokenDispatcher, IMintableTokenDispatcherTrait};
use super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use array::SpanTrait;
use super::token_bridge::TokenBridge::{Event, RoleAdminChanged, RoleGranted, RoleRevoked};


#[cfg(test)]
fn get_erc20_token(l2_token_address: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: l2_token_address }
}

#[cfg(test)]
fn caller() -> ContractAddress {
    starknet::contract_address_const::<15>()
}

#[cfg(test)]
fn not_caller() -> ContractAddress {
    starknet::contract_address_const::<16>()
}

#[cfg(test)]
fn initial_owner() -> ContractAddress {
    starknet::contract_address_const::<17>()
}

#[cfg(test)]
fn permitted_minter() -> ContractAddress {
    starknet::contract_address_const::<18>()
}

#[cfg(test)]
fn set_contract_address_as_caller() {
    let caller_address = caller();
    starknet::testing::set_contract_address(address: caller_address);
}

#[cfg(test)]
fn set_contract_address_as_not_caller() {
    let not_caller_address = not_caller();
    starknet::testing::set_contract_address(address: not_caller_address);
}


#[cfg(test)]
fn arbitrary_event(
    role: felt252, previous_admin_role: felt252, new_admin_role: felt252, 
) -> Event {
    Event::RoleAdminChanged(RoleAdminChanged { role, previous_admin_role, new_admin_role })
}


#[cfg(test)]
fn get_l2_token_deployment_calldata(
    initial_owner: ContractAddress, permitted_minter: ContractAddress, initial_supply: u256, 
) -> Span<felt252> {
    // Set the constructor calldata.
    let mut calldata = ArrayTrait::new();
    'NAME'.serialize(ref calldata);
    'SYMBOL'.serialize(ref calldata);
    18_u8.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    initial_owner.serialize(ref calldata);
    permitted_minter.serialize(ref calldata);

    calldata.span()
}


#[cfg(test)]
fn deploy_l2_token(
    initial_owner: ContractAddress, permitted_minter: ContractAddress, initial_supply: u256, 
) -> ContractAddress {
    let calldata = get_l2_token_deployment_calldata(
        :initial_owner, :permitted_minter, :initial_supply
    );

    // Deploy the contract.
    let (l2_token_address, _) = deploy_syscall(
        PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false
    )
        .unwrap();
    l2_token_address
}

#[cfg(test)]
fn get_mintable_token(l2_token_address: ContractAddress) -> IMintableTokenDispatcher {
    IMintableTokenDispatcher { contract_address: l2_token_address }
}

// Returns the last event in the queue. After this call, the evnet queue is empty.
#[cfg(test)]
fn pop_and_deserialize_last_event<T, impl TEvent: starknet::Event<T>>(
    address: ContractAddress
) -> T {
    let mut prev_log = starknet::testing::pop_log(address: address);
    let (mut keys, mut data) = loop {
        let log = starknet::testing::pop_log(address: address);
        match log {
            Option::Some(_) => {
                prev_log = log;
            },
            Option::None(()) => {
                break prev_log.unwrap();
            },
        };
    };
    let optional_event: Option<T> = starknet::Event::deserialize(ref keys, ref data);
    optional_event.expect('Event deserializion failed')
}


// Returns the last k raw events. After this call, the evnet queue is empty.
#[cfg(test)]
fn pop_last_k_events(
    address: ContractAddress, mut k: u32
) -> Span::<(Span::<felt252>, Span::<felt252>)> {
    assert(k > 0, 'Non-positive k');
    let mut events = ArrayTrait::new();
    loop {
        let log = starknet::testing::pop_log(address: address);
        match log {
            Option::Some(_) => {
                events.append(log.unwrap());
            },
            Option::None(()) => {
                break;
            },
        };
    };
    let n_evnets = events.len();
    assert(n_evnets >= k, 'k cant be greater than #events');
    (events.span()).slice(n_evnets - k, k)
}

#[cfg(test)]
fn validate_empty_event_queue(address: ContractAddress) {
    let log = starknet::testing::pop_log(address: address);
    assert(log.is_none(), 'Event queue is not empty')
}

#[cfg(test)]
fn deserialize_event<T, impl TEvent: starknet::Event<T>>(
    mut raw_event: (Span::<felt252>, Span::<felt252>)
) -> T {
    let (mut keys, mut data) = raw_event;
    starknet::Event::deserialize(ref keys, ref data).expect('Event deserializion failed')
}

#[cfg(test)]
fn assert_role_granted_event(
    mut raw_event: (Span::<felt252>, Span::<felt252>),
    role: felt252,
    account: ContractAddress,
    sender: ContractAddress
) {
    let role_granted_emitted_event = deserialize_event(:raw_event);
    assert(
        role_granted_emitted_event == RoleGranted { role: role, account: account, sender: sender },
        'RoleGranted was not emitted'
    );
}

#[cfg(test)]
fn assert_role_revoked_event(
    mut raw_event: (Span::<felt252>, Span::<felt252>),
    role: felt252,
    account: ContractAddress,
    sender: ContractAddress
) {
    let role_revoked_emitted_event = deserialize_event(:raw_event);
    assert(
        role_revoked_emitted_event == RoleRevoked { role: role, account: account, sender: sender },
        'RoleRevoked was not emitted'
    );
}
