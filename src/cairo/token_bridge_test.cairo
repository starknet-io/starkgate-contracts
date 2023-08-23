#[cfg(test)]
mod token_bridge_test {
    use array::ArrayTrait;
    use array::SpanTrait;

    use core::traits::Into;
    use core::result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use integer::BoundedInt;
    use serde::Serde;
    use starknet::SyscallResultTrait;

    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash, class_hash_const};
    use starknet::{contract_address_const, ContractAddress, EthAddress, ContractAddressIntoFelt252};
    use starknet::syscalls::deploy_syscall;

    use super::super::permissioned_erc20::PermissionedERC20;
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::token_bridge::TokenBridge;
    use super::super::token_bridge::TokenBridge::{
        Event, L1BridgeSet, L2TokenSet, WithdrawInitiated, DepositHandled, ImplementationAdded,
        ImplementationRemoved, ImplementationReplaced, ImplementationFinalized, RoleGranted,
        RoleRevoked, RoleAdminChanged, AppRoleAdminAdded, AppRoleAdminRemoved, UpgradeGovernorAdded,
        UpgradeGovernorRemoved, GovernanceAdminAdded, GovernanceAdminRemoved, AppGovernorAdded,
        AppGovernorRemoved, OperatorAdded, OperatorRemoved, TokenAdminAdded, TokenAdminRemoved,
        APP_GOVERNOR, APP_ROLE_ADMIN, GOVERNANCE_ADMIN, OPERATOR, TOKEN_ADMIN, UPGRADE_GOVERNOR,
    };
    use super::super::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use super::super::test_utils::{
        caller, not_caller, initial_owner, permitted_minter, set_contract_address_as_caller,
        set_contract_address_as_not_caller, get_erc20_token, deploy_l2_token,
        pop_and_deserialize_last_event, pop_last_k_events, deserialize_event, arbitrary_event,
        assert_role_granted_event, assert_role_revoked_event, validate_empty_event_queue
    };

    use super::super::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait
    };
    use super::super::roles_interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use super::super::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };

    const EXPECTED_CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const EXPECTED_CONTRACT_VERSION: felt252 = 2;

    const DEFAULT_UPGRADE_DELAY: u64 = 12345;

    const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
    const NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 6;

    const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
    const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;


    fn set_caller_as_app_role_admin_app_governor(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_app_governor(account: caller());
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

    fn get_token_bridge(token_bridge_address: ContractAddress) -> ITokenBridgeDispatcher {
        ITokenBridgeDispatcher { contract_address: token_bridge_address }
    }


    fn get_replaceable(token_bridge_address: ContractAddress) -> IReplaceableDispatcher {
        IReplaceableDispatcher { contract_address: token_bridge_address }
    }

    fn get_roles(token_bridge_address: ContractAddress) -> IRolesDispatcher {
        IRolesDispatcher { contract_address: token_bridge_address }
    }

    fn get_access_control(token_bridge_address: ContractAddress) -> IAccessControlDispatcher {
        IAccessControlDispatcher { contract_address: token_bridge_address }
    }


    fn dummy_replaceable_data(final: bool) -> ImplementationData {
        // Set the eic_init_data calldata.
        let mut calldata = ArrayTrait::new();
        'dummy'.serialize(ref calldata);
        'arbitrary'.serialize(ref calldata);
        'values'.serialize(ref calldata);

        ImplementationData {
            impl_hash: class_hash_const::<17171>(),
            eic_hash: class_hash_const::<343434>(),
            eic_init_data: calldata.span(),
            final: final
        }
    }


    fn get_dummy_nonfinal_replaceable_data() -> ImplementationData {
        dummy_replaceable_data(final: false)
    }

    fn get_dummy_final_replaceable_data() -> ImplementationData {
        dummy_replaceable_data(final: true)
    }

    // Deploys the token bridge and sets the caller as the app governer (and as App Role Admin).
    // Returns the token bridge.
    fn deploy_and_prepare() -> ITokenBridgeDispatcher {
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);
        get_token_bridge(:token_bridge_address)
    }

    #[test]
    #[available_gas(30000000)]
    fn test_identity_and_version() {
        let token_bridge = deploy_and_prepare();

        // Verify identity and version.
        assert(
            token_bridge.get_identity() == EXPECTED_CONTRACT_IDENTITY, 'Contract identity mismatch.'
        );
        assert(
            token_bridge.get_version() == EXPECTED_CONTRACT_VERSION, 'Contract version mismatch.'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_l1_bridge() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 Eth address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == L1BridgeSet { l1_bridge_address: l1_bridge_address },
            'L1BridgeSet Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_missing_role_set_l1_bridge() {
        let token_bridge = deploy_and_prepare();

        // Set an arbitrary l1 Eth address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Set the l1 bridge not as the App Governor.
        set_contract_address_as_not_caller();
        token_bridge.set_l1_bridge(:l1_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('L1_BRIDGE_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_already_set_l1_bridge() {
        let token_bridge = deploy_and_prepare();

        // Set an arbitrary l1 Eth address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Set the l1 bridge twice.
        token_bridge.set_l1_bridge(:l1_bridge_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('ZERO_L1_BRIDGE_ADDRESS', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_zero_address_set_l1_bridge() {
        let token_bridge = deploy_and_prepare();

        // Set the l1 bridge with a 0 address.
        token_bridge.set_l1_bridge(l1_bridge_address: EthAddress { address: 0 });
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_l2_token() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: permitted_minter(),
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );

        // Set the l2 contract address on the token bridge.
        token_bridge.set_l2_token(:l2_token_address);

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == L2TokenSet { l2_token_address: l2_token_address }, 'L2TokenSet Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_missing_role_set_l2_token() {
        let token_bridge = deploy_and_prepare();

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: permitted_minter(),
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );

        // Set the l2 contract address not as the caller.
        set_contract_address_as_not_caller();
        token_bridge.set_l2_token(:l2_token_address);
    }

    #[test]
    #[should_panic(expected: ('L2_TOKEN_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_already_set_l2_token() {
        let token_bridge = deploy_and_prepare();

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: permitted_minter(),
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );

        // Set the l2 contract address on the token bridge twice.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l2_token(:l2_token_address);
    }

    #[test]
    #[should_panic(expected: ('ZERO_L2_TOKEN_ADDRESS', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_zero_address_set_l2_token() {
        let token_bridge = deploy_and_prepare();

        // Set the l2 contract address as 0.
        token_bridge.set_l2_token(l2_token_address: starknet::contract_address_const::<0>());
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_initate_withdraw() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = initial_owner();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set the l1 bridge and the l2 token addresses in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Initate withdraw (set the caller to be the initial_owner).
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        starknet::testing::set_contract_address(address: initial_owner);
        token_bridge.initiate_withdraw(:l1_recipient, :amount);

        // Validate the new balance and total supply.
        assert(
            erc20_token.balance_of(initial_owner) == u256 {
                low: 300, high: DEFAULT_INITIAL_SUPPLY_HIGH
            },
            'INIT_WITHDRAW_BALANCE_ERROR'
        );
        assert(
            erc20_token.total_supply() == u256 { low: 300, high: DEFAULT_INITIAL_SUPPLY_HIGH },
            'INIT_WITHDRAW_SUPPLY_ERROR'
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == WithdrawInitiated {
                l1_recipient: l1_recipient, amount: amount, caller_address: initial_owner
            },
            'WithdrawInitiated Error'
        );
    }

    #[test]
    #[should_panic(expected: ('UNINITIALIZED_L2_TOKEN', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_l2_token_not_set_initate_withdraw() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set only the l1 bridge address, but not the the l2 token address, in the token bridge.
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Initate withdraw without previously setting the l2 contract address on the token bridge.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
    }

    #[test]
    #[should_panic(expected: ('UNINITIALIZED_L1_BRIDGE_ADDRESS', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_l1_bridge_not_set_initate_withdraw() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set only the l2 token address, but not the the l2 bridge address, in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);

        // Initate withdraw without previously setting the l2 contract address on the token bridge.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
    }

    #[test]
    #[should_panic(expected: ('ZERO_WITHDRAWAL', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_zero_amount_initate_withdraw() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set the l1 bridge and the l2 token addresses in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Initate withdraw.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 0, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_FUNDS', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_excessive_amount_initate_withdraw() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let l2_token_address = deploy_l2_token(
            initial_owner: initial_owner(),
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set the l1 bridge and the l2 token addresses in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Initate withdraw.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 {
            low: DEFAULT_INITIAL_SUPPLY_LOW + 1, high: DEFAULT_INITIAL_SUPPLY_HIGH
        };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_deposit() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = initial_owner();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set the l1 bridge and the l2 token addresses in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Simulate an "handle_deposit" l1 message.
        let deposit_amount_low: u128 = 17;
        let amount = u256 { low: deposit_amount_low, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            account: initial_owner,
            amount: amount
        );

        assert(
            erc20_token.balance_of(initial_owner) == u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW + deposit_amount_low,
                high: DEFAULT_INITIAL_SUPPLY_HIGH
            },
            'HANDLE_DEPOSIT_AMOUNT_FAILED'
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == DepositHandled { account: initial_owner, amount: amount },
            'DepositHandled Error'
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY', ))]
    #[available_gas(30000000)]
    fn test_non_l1_token_message_handle_deposit() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = initial_owner();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token_address);

        // Set the l1 bridge and the l2 token addresses in the token bridge.
        token_bridge.set_l2_token(:l2_token_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Simulate an "handle_deposit" l1 message from an incorrect Ethereum address.
        let l1_not_bridge_address = EthAddress { address: NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit(
            ref token_bridge_state,
            from_address: l1_not_bridge_address.into(),
            account: initial_owner,
            amount: u256 { low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH }
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_get_upgrade_delay() {
        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);

        // Validate the upgrade delay.
        assert(
            token_bridge.get_upgrade_delay() == DEFAULT_UPGRADE_DELAY, 'DEFAULT_UPGRADE_DELAY_ERROR'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Check implementation time pre addition.
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        token_bridge.add_new_implementation(:implementation_data);

        // Check implementation time post addition.
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == DEFAULT_UPGRADE_DELAY,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == ImplementationAdded { implementation_data: implementation_data },
            'ImplementationAdded Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Invoke not as an Upgrade Governor.
        let not_governor_address = not_caller();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.add_new_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Remove implementation that was not previously added.
        // TODO the following should NOT emit an event.
        token_bridge.remove_implementation(:implementation_data);
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Add implementation.
        token_bridge.add_new_implementation(:implementation_data);

        // Validate event emission for adding the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == ImplementationAdded { implementation_data: implementation_data },
            'ImplementationAdded Error'
        );

        // Remove implementation
        token_bridge.remove_implementation(:implementation_data);

        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate event emission for removing the implementation.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == ImplementationRemoved { implementation_data: implementation_data },
            'ImplementationRemoved Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        token_bridge.remove_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_nonfinal() {
        // Tests replacing an implementation to a non-final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a non-final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implemenation is not final

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == ImplementationReplaced { implementation_data: implementation_data },
            'ImplementationReplaced Error'
        );
    // TODO check the new impl hash.
    // TODO check the new impl is not final.
    // TODO check that ImplementationFinalized is NOT emitted.
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_final() {
        // Tests replacing an implementation to a final implementation, as follows:
        // 1. deploys a replaceable contract
        // 2. generates a final dummy implementation replacement
        // 3. adds it to the replaceable contract
        // 4. advances time until the new implementation is ready
        // 5. replaces to the new implemenation
        // 6. checks the implementation is final

        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data();

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);

        // Validate event emissions -- replacement and finalization of the implementation.
        let implementation_events = pop_last_k_events(address: token_bridge_address, k: 2);

        let implementation_replaced_event = deserialize_event(
            raw_event: *implementation_events.at(0)
        );
        assert(
            implementation_replaced_event == ImplementationReplaced {
                implementation_data: implementation_data
            },
            'ImplementationReplaced Error'
        );

        let implementation_finalized_event = deserialize_event(
            raw_event: *implementation_events.at(1)
        );
        assert(
            implementation_finalized_event == ImplementationFinalized {
                impl_hash: implementation_data.impl_hash
            },
            'ImplementationFinalized Error'
        );
    // TODO check the new impl hash.
    // TODO check the new impl is final.
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_not_upgrade_governor() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data();

        // Invoke not as an Upgrade Governor.
        set_contract_address_as_not_caller();
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('FINALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_already_final() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data();

        // Set the contract address to be of the token bridge, so we can call the internal
        // finalize() function on the replaceable contract state.
        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::InternalFunctions::finalize(ref token_bridge_state);

        set_contract_address_as_caller();
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_unknown_implementation() {
        // Deploy the token bridge and set the caller as an Upgrade Governor.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_replaceable(:token_bridge_address);
        set_caller_as_upgrade_governor(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data();

        // Calling replace_to without previously adding the implementation.
        token_bridge.replace_to(:implementation_data);
    }

    // Tests the functionality of the internal function grant_role_and_emit
    // which is commonly used by all role registration functions.
    #[test]
    #[available_gas(30000000)]
    fn test_grant_role_and_emit() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_acess_control = get_access_control(:token_bridge_address);

        // Set admin_of_arbitrary_role as an admin role of arbitrary_role and then grant the caller
        // the role of admin_of_arbitrary_role.
        let arbitrary_role: felt252 = 'ARBITRARY';
        let admin_of_arbitrary_role: felt252 = 'ADMIN_OF_ARBITRARY';

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: token_bridge_address);
        TokenBridge::InternalFunctions::_set_role_admin(
            ref token_bridge_state, role: arbitrary_role, admin_role: admin_of_arbitrary_role
        );
        TokenBridge::InternalFunctions::_grant_role(
            ref token_bridge_state, role: admin_of_arbitrary_role, account: caller()
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'Account should not have role'
        );

        // Set caller address for the _grant_role_and_emit.
        starknet::testing::set_caller_address(address: caller());

        // Set the token bridge address to be the contract address since we are calling internal
        // functions later.
        starknet::testing::set_contract_address(address: token_bridge_address);

        // The caller grant arbitrary_account the role of arbitrary_role.
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_1';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::InternalFunctions::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        assert(
            token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'grant_role to account failed'
        );

        // Validate event emission.
        let arbitrary_emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            arbitrary_emitted_event == RoleAdminChanged {
                role, previous_admin_role, new_admin_role
            },
            'Arbitrary event was not emitted'
        );

        // Uneventful success in redundant registration.
        // I.e. If an account holds a role, re-registering it will not fail, but will not incur
        // any state change or emission of event.
        starknet::testing::set_contract_address(address: token_bridge_address);
        TokenBridge::InternalFunctions::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
        validate_empty_event_queue(address: token_bridge_address);
    }
    #[test]
    #[should_panic(expected: ('INVALID_ACCOUNT_ADDRESS', ))]
    #[available_gas(30000000)]
    fn test_grant_role_and_emit_zero_account() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let arbitrary_role: felt252 = 'ARBITRARY';
        let zero_account = starknet::contract_address_const::<0>();
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_0';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::InternalFunctions::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: zero_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
    }
    // Tests the functionality of the internal function revoke_role_and_emit which is commonly used
    // by all role removal functions.
    #[test]
    #[available_gas(30000000)]
    fn test_revoke_role_and_emit() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_acess_control = get_access_control(:token_bridge_address);

        // Set admin_of_arbitrary_role as an admin role of arbitrary_role and then grant the caller
        // the role of admin_of_arbitrary_role.
        let arbitrary_role: felt252 = 'ARBITRARY';
        let admin_of_arbitrary_role: felt252 = 'ADMIN_OF_ARBITRARY';

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: token_bridge_address);
        TokenBridge::InternalFunctions::_set_role_admin(
            ref token_bridge_state, role: arbitrary_role, admin_role: admin_of_arbitrary_role
        );
        TokenBridge::InternalFunctions::_grant_role(
            ref token_bridge_state, role: admin_of_arbitrary_role, account: caller()
        );

        let arbitrary_account = not_caller();
        TokenBridge::InternalFunctions::_grant_role(
            ref token_bridge_state, role: arbitrary_role, account: arbitrary_account
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // token_bridge_acess_control dispatcher.
        set_contract_address_as_caller();
        assert(
            token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'grant_role to account failed'
        );
        // Set caller address for the _revoke_role_and_emit.
        starknet::testing::set_caller_address(address: caller());

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: token_bridge_address);

        // The caller revoke arbitrary_account the role of arbitrary_role.
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_1';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::InternalFunctions::_revoke_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        assert(
            !token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'Revoke role failed'
        );

        // Validate event emission.
        let arbitrary_emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            arbitrary_emitted_event == RoleAdminChanged {
                role, previous_admin_role, new_admin_role
            },
            'Arbitrary event was not emitted'
        );

        // Uneventful success in redundant removal.
        // I.e. If an account does not hold a role, removing the role will not fail, but will not
        // incur any state change or emission of event.
        starknet::testing::set_contract_address(address: token_bridge_address);
        TokenBridge::InternalFunctions::_revoke_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
        validate_empty_event_queue(address: token_bridge_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_initialize_roles() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        // Validate that by default, 0 is the role admin of all roles.
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: APP_GOVERNOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: APP_ROLE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: GOVERNANCE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: OPERATOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: TOKEN_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImpl::get_role_admin(
                @token_bridge_state, role: UPGRADE_GOVERNOR
            ) == 0,
            '0 should be default role admin'
        );

        // deploy_token_bridge calls the constructor which calls _initialize_roles.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_acess_control = get_access_control(:token_bridge_address);

        // Validate that provisional_governance_admin is the GOVERNANCE_ADMIN.
        assert(
            token_bridge_acess_control.has_role(role: GOVERNANCE_ADMIN, account: caller()),
            'grant_role to account failed'
        );

        // Validate that each role has the right role admin.
        assert(
            token_bridge_acess_control.get_role_admin(role: APP_GOVERNOR) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: APP_ROLE_ADMIN) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: GOVERNANCE_ADMIN) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: OPERATOR) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: TOKEN_ADMIN) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: UPGRADE_GOVERNOR) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
    }
    #[test]
    #[should_panic(expected: ('ROLES_ALREADY_INITIALIZED', ))]
    #[available_gas(30000000)]
    fn test_initialize_roles_already_set() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::InternalFunctions::_initialize_roles(
            ref token_bridge_state, provisional_governance_admin: not_caller()
        );
        TokenBridge::InternalFunctions::_initialize_roles(
            ref token_bridge_state, provisional_governance_admin: not_caller()
        );
    }

    #[test]
    #[should_panic(expected: ('ZERO_PROVISIONAL_GOV_ADMIN', ))]
    #[available_gas(30000000)]
    fn test_initialize_roles_zero_account() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::InternalFunctions::_initialize_roles(
            ref token_bridge_state,
            provisional_governance_admin: starknet::contract_address_const::<0>()
        );
    }
    // Validates is_app_governor function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the App Governor role.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: APP_ROLE_ADMIN, account: caller());
        token_bridge_acess_control.grant_role(role: APP_GOVERNOR, account: arbitrary_account);

        assert(token_bridge_roles.is_app_governor(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_app_role_admin function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_app_role_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary_account the App Role Admin role by the caller.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: APP_ROLE_ADMIN, account: arbitrary_account);

        assert(
            token_bridge_roles.is_app_role_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_governance_admin function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_governance_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_governance_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary_account the Governance Admin role by the caller.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: GOVERNANCE_ADMIN, account: arbitrary_account);

        assert(
            token_bridge_roles.is_governance_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_operator_admin function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_operator() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the Operator role.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: APP_ROLE_ADMIN, account: caller());
        token_bridge_acess_control.grant_role(role: OPERATOR, account: arbitrary_account);

        assert(token_bridge_roles.is_operator(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_token_admin function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the Token Admin role.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: APP_ROLE_ADMIN, account: caller());
        token_bridge_acess_control.grant_role(role: TOKEN_ADMIN, account: arbitrary_account);

        assert(token_bridge_roles.is_token_admin(account: arbitrary_account), 'Role not granted');
    }
    // Validates is_upgrade_governor function, under the assumption that grant_role, functions as
    // expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_upgrade_governor() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary account the Upgrade Governor role.
        let token_bridge_acess_control = get_access_control(:token_bridge_address);
        token_bridge_acess_control.grant_role(role: UPGRADE_GOVERNOR, account: arbitrary_account);

        assert(
            token_bridge_roles.is_upgrade_governor(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates register_app_governor and remove_app_governor functions under the assumption
    // that is_app_governor functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant App Governor role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_app_governor(account: arbitrary_account);
        assert(
            token_bridge_roles.is_app_governor(account: arbitrary_account),
            'register_app_governor failed'
        );

        // Validate the two App Governor registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: APP_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == AppGovernorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'AppGovAdded was not emitted'
        );

        token_bridge_roles.remove_app_governor(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'remove_app_governor failed'
        );

        // Validate the two App Governor removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: APP_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );
        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == AppGovernorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'AppGovRemoved was not emitted'
        );
    }


    // Validates register_app_role_admin and remove_app_role_admin functions under the assumption
    // that is_app_role_admin, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_app_role_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_app_role_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'register_app_role_admin failed'
        );

        // Validate the two App Role Admin registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: APP_ROLE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == AppRoleAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'AppRoleAdminAdded wasnt emitted'
        );

        token_bridge_roles.remove_app_role_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'remove_app_role_admin failed'
        );

        // Validate the two App Role Admin removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: APP_ROLE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == AppRoleAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'AppRoleAdminRemoved not emitted'
        );
    }

    // Validates register_governance_admin and remove_governance_admin functions under the
    // assumption that is_governance_admin, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_governance_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_governance_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_governance_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_governance_admin(account: arbitrary_account),
            'register_governance_adm failed'
        );

        // Validate the two Governance Admin registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: GOVERNANCE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == GovernanceAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'GovAdminAdded was not emitted'
        );

        token_bridge_roles.remove_governance_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_governance_admin(account: arbitrary_account),
            'remove_governance_admin failed'
        );

        // Validate the two Governance Admin removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: GOVERNANCE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == GovernanceAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'GovAdminRemoved was not emitted'
        );
    }

    // Validates register_operator and remove_operator functions under the assumption
    // that is_operator functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_operator() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant Operator role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_operator(account: arbitrary_account);
        assert(
            token_bridge_roles.is_operator(account: arbitrary_account), 'register_operator failed'
        );

        // Validate the two Operator registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: OPERATOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == OperatorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'OperatorAdded was not emitted'
        );

        token_bridge_roles.remove_operator(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'remove_operator failed'
        );

        // Validate the two Operator removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: OPERATOR,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == OperatorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'OperatorRemoved was not emitted'
        );
    }


    // Validates register_token_admin and remove_token_admin functions under the assumption
    // that is_token_admin functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant Token Admin role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_token_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_token_admin(account: arbitrary_account),
            'register_token_admin failed'
        );

        // Validate the two Token Admin registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: TOKEN_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == TokenAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'TokenAdminAdded was not emitted'
        );

        token_bridge_roles.remove_token_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'remove_token_admin failed'
        );

        // Validate the two Token Admin removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: TOKEN_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );
        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == TokenAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'TokenAdminRemoved wasnt emitted'
        );
    }


    // Validates register_upgrade_governor and remove_upgrade_governor functions under the
    // assumption that is_upgrade_governor, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_upgrade_governor() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_upgrade_governor(account: arbitrary_account);
        assert(
            token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'register_upgrade_gov failed'
        );

        // Validate the two Upgrade Governor registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: UPGRADE_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == UpgradeGovernorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'UpgradeGovAdded was not emitted'
        );

        token_bridge_roles.remove_upgrade_governor(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'remove_upgrade_governor failed'
        );

        // Validate the two Upgrade Governor removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: UPGRADE_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == UpgradeGovernorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'UpgradeGovRemoved wasnt emitted'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_renounce() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        token_bridge_roles.register_upgrade_governor(account: arbitrary_account);
        assert(
            token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'register_upgrade_gov failed'
        );

        starknet::testing::set_contract_address(address: arbitrary_account);
        token_bridge_roles.renounce(role: UPGRADE_GOVERNOR);
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account), 'renounce failed'
        );

        // Validate event emission.
        let role_revoked_emitted_event = pop_and_deserialize_last_event(
            address: token_bridge_address
        );
        assert(
            role_revoked_emitted_event == RoleRevoked {
                role: UPGRADE_GOVERNOR, account: arbitrary_account, sender: arbitrary_account
            },
            'RoleRevoked was not emitted'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_void_renounce() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Empty the event queue.
        pop_last_k_events(address: token_bridge_address, k: 1);

        // The caller, which does not have an Upgrade Governor role, try to renounce this role.
        // Nothing should happen.
        token_bridge_roles.renounce(role: UPGRADE_GOVERNOR);
        assert(
            !token_bridge_roles.is_upgrade_governor(account: arbitrary_account),
            'Unexpected role detected'
        );
        validate_empty_event_queue(token_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('GOV_ADMIN_CANNOT_SELF_REMOVE', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_renounce_governance_admin() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.renounce(role: GOVERNANCE_ADMIN);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_app_governor(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: token_bridge_address);
        // Set the caller to be arbitrary_account as it is the App Governor.
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::InternalFunctions::only_app_governor(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', ))]
    #[available_gas(30000000)]
    fn test_only_app_governor_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_app_governor(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_app_role_admin() {
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register arbitrary account as an App Role Admin.
        let arbitrary_account = not_caller();
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::InternalFunctions::only_app_role_admin(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_ROLE_ADMIN', ))]
    #[available_gas(30000000)]
    fn test_only_app_role_admin_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_app_role_admin(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_governance_admin() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: caller());
        TokenBridge::InternalFunctions::only_governance_admin(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_GOVERNANCE_ADMIN', ))]
    #[available_gas(30000000)]
    fn test_only_governance_admin_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_governance_admin(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_operator() {
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_operator(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::InternalFunctions::only_operator(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_OPERATOR', ))]
    #[available_gas(30000000)]
    fn test_only_operator_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_operator(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_token_admin(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::InternalFunctions::only_token_admin(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_TOKEN_ADMIN', ))]
    #[available_gas(30000000)]
    fn test_only_token_admin_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_token_admin(@token_bridge_state);
    }
    #[test]
    #[available_gas(30000000)]
    fn test_only_upgrade_governor() {
        let token_bridge_address = deploy_token_bridge();

        let arbitrary_account = not_caller();
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_upgrade_governor(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::InternalFunctions::only_upgrade_governor(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', ))]
    #[available_gas(30000000)]
    fn test_only_upgrade_governor_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_upgrade_governor(@token_bridge_state);
    }
}
