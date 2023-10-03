#[cfg(test)]
mod test_utils {
    use array::ArrayTrait;
    use core::result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use serde::Serde;
    use starknet::{ContractAddress, syscalls::deploy_syscall};
    use super::super::permissioned_erc20::PermissionedERC20;
    use openzeppelin::token::erc20::presets::erc20votes::ERC20VotesPreset;

    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use array::SpanTrait;
    use super::super::token_bridge::TokenBridge;
    use super::super::token_bridge::TokenBridge::{
        Event, RoleAdminChanged, RoleGranted, RoleRevoked
    };

    use super::super::replaceability_interface::{
        IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait
    };
    use super::super::roles_interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use super::super::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait, RoleId
    };

    const DEFAULT_UPGRADE_DELAY: u64 = 12345;


    fn get_roles(token_bridge_address: ContractAddress) -> IRolesDispatcher {
        IRolesDispatcher { contract_address: token_bridge_address }
    }

    fn get_replaceable(token_bridge_address: ContractAddress) -> IReplaceableDispatcher {
        IReplaceableDispatcher { contract_address: token_bridge_address }
    }

    fn get_access_control(token_bridge_address: ContractAddress) -> IAccessControlDispatcher {
        IAccessControlDispatcher { contract_address: token_bridge_address }
    }


    fn get_erc20_token(l2_token_address: ContractAddress) -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: l2_token_address }
    }


    fn caller() -> ContractAddress {
        starknet::contract_address_const::<15>()
    }


    fn not_caller() -> ContractAddress {
        starknet::contract_address_const::<16>()
    }


    fn initial_owner() -> ContractAddress {
        starknet::contract_address_const::<17>()
    }


    fn permitted_minter() -> ContractAddress {
        starknet::contract_address_const::<18>()
    }


    fn set_contract_address_as_caller() {
        let caller_address = caller();
        starknet::testing::set_contract_address(address: caller_address);
    }


    fn set_contract_address_as_not_caller() {
        let not_caller_address = not_caller();
        starknet::testing::set_contract_address(address: not_caller_address);
    }


    fn arbitrary_event(
        role: RoleId, previous_admin_role: RoleId, new_admin_role: RoleId,
    ) -> Event {
        Event::RoleAdminChanged(RoleAdminChanged { role, previous_admin_role, new_admin_role })
    }


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


    fn get_l2_votes_token_deployment_calldata(
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
        'WEN_TOKEN_DAPP'.serialize(ref calldata);
        '1.0.0'.serialize(ref calldata);
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
        calldata.span()
    }


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


    fn deploy_l2_votes_token(
        initial_owner: ContractAddress, permitted_minter: ContractAddress, initial_supply: u256,
    ) -> ContractAddress {
        let calldata = get_l2_votes_token_deployment_calldata(
            :initial_owner, :permitted_minter, :initial_supply
        );

        // Set the caller address for all the functions calls (except the constructor).
        set_contract_address_as_caller();

        // Set the caller address for the constructor.
        starknet::testing::set_caller_address(address: caller());

        // Deploy the contract.
        let (l2_votes_token_address, _) = deploy_syscall(
            ERC20VotesPreset::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false
        )
            .unwrap();
        l2_votes_token_address
    }


    fn get_mintable_token(l2_token_address: ContractAddress) -> IMintableTokenDispatcher {
        IMintableTokenDispatcher { contract_address: l2_token_address }
    }

    // Returns the last event in the queue. After this call, the evnet queue is empty.

    fn pop_and_deserialize_last_event<T, impl TEvent: starknet::Event<T>, impl TDrop: Drop<T>>(
        address: ContractAddress
    ) -> T {
        let mut prev_log: T = starknet::testing::pop_log(address: address)
            .expect('Event deserializion failed');
        loop {
            match starknet::testing::pop_log::<T>(:address) {
                Option::Some(log) => {
                    prev_log = log;
                },
                Option::None(()) => {
                    break;
                },
            };
        };
        prev_log
    }


    // Returns the last k raw events. After this call, the evnet queue is empty.

    fn pop_last_k_events(
        address: ContractAddress, mut k: u32
    ) -> Span::<(Span::<felt252>, Span::<felt252>)> {
        assert(k > 0, 'Non-positive k');
        let mut events = ArrayTrait::new();
        loop {
            let log = starknet::testing::pop_log_raw(address: address);
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


    fn validate_empty_event_queue(address: ContractAddress) {
        let log = starknet::testing::pop_log_raw(address: address);
        assert(log.is_none(), 'Event queue is not empty')
    }


    fn deserialize_event<T, impl TEvent: starknet::Event<T>>(
        mut raw_event: (Span::<felt252>, Span::<felt252>)
    ) -> T {
        let (mut keys, mut data) = raw_event;
        starknet::Event::deserialize(ref keys, ref data).expect('Event deserializion failed')
    }


    fn assert_role_granted_event(
        mut raw_event: (Span::<felt252>, Span::<felt252>),
        role: RoleId,
        account: ContractAddress,
        sender: ContractAddress
    ) {
        let role_granted_emitted_event = deserialize_event(:raw_event);
        assert(
            role_granted_emitted_event == RoleGranted {
                role: role, account: account, sender: sender
            },
            'RoleGranted was not emitted'
        );
    }


    fn assert_role_revoked_event(
        mut raw_event: (Span::<felt252>, Span::<felt252>),
        role: RoleId,
        account: ContractAddress,
        sender: ContractAddress
    ) {
        let role_revoked_emitted_event = deserialize_event(:raw_event);
        assert(
            role_revoked_emitted_event == RoleRevoked {
                role: role, account: account, sender: sender
            },
            'RoleRevoked was not emitted'
        );
    }


    fn set_caller_as_upgrade_governor(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_upgrade_governor(account: caller());
    }

    fn deploy_token_bridge() -> ContractAddress {
        // Set the constructor calldata.
        let mut calldata = ArrayTrait::new();
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);

        // Set the caller address for all the functions calls (except the constructor).
        set_contract_address_as_caller();

        // Set the caller address for the constructor.
        starknet::testing::set_caller_address(address: caller());

        // Deploy the contract.
        let (token_bridge_address, _) = deploy_syscall(
            TokenBridge::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false
        )
            .unwrap();
        token_bridge_address
    }
}
