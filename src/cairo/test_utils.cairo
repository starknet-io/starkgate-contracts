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


#[cfg(test)]
fn get_erc20_token(l2_token_address: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: l2_token_address }
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

#[cfg(test)]
fn pop_and_deserialize_event<T, impl TEvent: starknet::Event<T>>(address: ContractAddress) -> T {
    let (mut keys, mut data) = starknet::testing::pop_log(address: address).unwrap();
    starknet::Event::deserialize(ref keys, ref data).unwrap()
}
