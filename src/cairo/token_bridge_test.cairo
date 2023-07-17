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
        RoleRevoked, RoleAdminChanged,
    };
    use super::super::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use super::super::test_utils::{get_erc20_token, deploy_l2_token, pop_and_deserialize_event};

    use super::super::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait
    };

    const EXPECTED_CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const EXPECTED_CONTRACT_VERSION: felt252 = 2;

    const DEFAULT_UPGRADE_DELAY: u64 = 12345;

    const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
    const NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 6;

    const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
    const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;

    fn deploy_token_bridge(governor_address: ContractAddress) -> ContractAddress {
        // Set the constructor calldata.
        let mut calldata = ArrayTrait::new();
        governor_address.serialize(ref calldata);
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);

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

    fn get_dummy_replaceable_data(
        governor_address: ContractAddress, final: bool
    ) -> ImplementationData {
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


    fn get_dummy_nonfinal_replaceable_data(
        governor_address: ContractAddress
    ) -> ImplementationData {
        get_dummy_replaceable_data(:governor_address, final: false)
    }

    fn get_dummy_final_replaceable_data(governor_address: ContractAddress) -> ImplementationData {
        get_dummy_replaceable_data(:governor_address, final: true)
    }

    fn deploy_and_get_token_bridge() -> ITokenBridgeDispatcher {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        get_token_bridge(:token_bridge_address)
    }

    #[test]
    #[available_gas(30000000)]
    fn test_identity_and_version() {
        // Deploy token bridge with an arbitrary governor address.
        let token_bridge_address = deploy_token_bridge(
            governor_address: starknet::contract_address_const::<100>()
        );
        let token_bridge = get_token_bridge(:token_bridge_address);

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
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 Eth address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Validate event emission.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == L1BridgeSet { l1_bridge_address: l1_bridge_address },
            'L1BridgeSet Error'
        );
    }

    #[test]
    #[should_panic(expected: ('GOVERNOR_ONLY', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_not_governor_set_l1_bridge() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 Eth address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Set the l1 bridge not as the governor.
        let not_governor_address = starknet::contract_address_const::<11>();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.set_l1_bridge(:l1_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('L1_BRIDGE_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_already_set_l1_bridge() {
        let token_bridge = deploy_and_get_token_bridge();

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
        let token_bridge = deploy_and_get_token_bridge();

        // Set the l1 bridge with a 0 address.
        token_bridge.set_l1_bridge(l1_bridge_address: EthAddress { address: 0 });
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_l2_token() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            :permitted_minter,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );

        // Set the l2 contract address on the token bridge.
        token_bridge.set_l2_token(:l2_token_address);

        // Validate event emission.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == L2TokenSet { l2_token_address: l2_token_address }, 'L2TokenSet Error'
        );
    }

    #[test]
    #[should_panic(expected: ('GOVERNOR_ONLY', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_not_governor_set_l2_token() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            :permitted_minter,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );

        // Set the l2 contract address not as the governor.
        let not_governor_address = starknet::contract_address_const::<11>();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.set_l2_token(:l2_token_address);
    }

    #[test]
    #[should_panic(expected: ('L2_TOKEN_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_double_set_l2_token() {
        let token_bridge = deploy_and_get_token_bridge();

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
            :permitted_minter,
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
        let token_bridge = deploy_and_get_token_bridge();

        // Set the l2 contract address as 0.
        token_bridge.set_l2_token(l2_token_address: starknet::contract_address_const::<0>());
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_initate_withdraw() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
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

        // Initate withdraw.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);

        // Validate the new balance and total supply.
        assert(
            erc20_token.balance_of(governor_address) == u256 {
                low: 300, high: DEFAULT_INITIAL_SUPPLY_HIGH
            },
            'INIT_WITHDRAW_BALANCE_ERROR'
        );
        assert(
            erc20_token.total_supply() == u256 { low: 300, high: DEFAULT_INITIAL_SUPPLY_HIGH },
            'INIT_WITHDRAW_SUPPLY_ERROR'
        );

        // Validate event emission.

        // Clear the two setting events.
        starknet::testing::pop_log(address: token_bridge_address);
        starknet::testing::pop_log(address: token_bridge_address);

        // Read expected event data.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == WithdrawInitiated {
                l1_recipient: l1_recipient, amount: amount, caller_address: initial_owner
            },
            'WithdrawInitiated Error'
        );
    }

    #[test]
    #[should_panic(expected: ('UNINITIALIZED_L2_TOKEN', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_l2_token_not_set_initate_withdraw() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
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
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
        let l2_token_address = deploy_l2_token(
            :initial_owner,
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
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
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

        // Initate withdraw.
        let l1_recipient = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let amount: u256 = u256 { low: 0, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_FUNDS', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_excessive_amount_initate_withdraw() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
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
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
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

        // Clear the two setting events.
        starknet::testing::pop_log(address: token_bridge_address);
        starknet::testing::pop_log(address: token_bridge_address);

        // Read expected event data.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == DepositHandled { account: initial_owner, amount: amount },
            'DepositHandled Error'
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY', ))]
    #[available_gas(30000000)]
    fn test_non_l1_token_message_handle_deposit() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = starknet::contract_address_const::<10>();
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
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        // Validate the upgrade delay.
        assert(
            token_bridge.get_upgrade_delay() == DEFAULT_UPGRADE_DELAY, 'DEFAULT_UPGRADE_DELAY_ERROR'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

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
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationAdded { implementation_data: implementation_data },
            'ImplementationAdded Error'
        );
    }

    #[test]
    #[should_panic(expected: ('GOVERNOR_ONLY', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_add_new_implementation_not_governor() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

        // Invoke not as a governor.
        let not_governor_address = starknet::contract_address_const::<11>();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.add_new_implementation(:implementation_data);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

        // Remove implementation that was not previously added.
        // TODO the following should NOT emit an event.
        token_bridge.remove_implementation(:implementation_data);
        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Add and remove implementation.
        token_bridge.add_new_implementation(:implementation_data);
        // TODO the following should emit an event.
        token_bridge.remove_implementation(:implementation_data);

        assert(
            token_bridge.get_impl_activation_time(:implementation_data) == 0,
            'INCORRECT_IMPLEMENTATION_ERROR'
        );

        // Validate two event emissions -- one for adding the implementation and one for its
        // removal.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationAdded { implementation_data: implementation_data },
            'ImplementationAdded Error'
        );
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationRemoved { implementation_data: implementation_data },
            'ImplementationRemoved Error'
        );
    }

    #[test]
    #[should_panic(expected: ('GOVERNOR_ONLY', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_remove_implementation_not_governor() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

        // Invoke not as a governor.
        let not_governor_address = starknet::contract_address_const::<11>();
        starknet::testing::set_contract_address(not_governor_address);
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

        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

        // Add implementation and advance time to enable it.
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);

        // Validate event emission.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationReplaced { implementation_data: implementation_data },
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

        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data(:governor_address);

        // Add implementation and advance time to enable it. 
        token_bridge.add_new_implementation(:implementation_data);
        starknet::testing::set_block_timestamp(DEFAULT_UPGRADE_DELAY + 1);

        token_bridge.replace_to(:implementation_data);

        // Validate event emissions -- replacement and finalization of the implementation.
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationReplaced { implementation_data: implementation_data },
            'ImplementationReplaced Error'
        );
        let expected_event = pop_and_deserialize_event(address: token_bridge_address);
        assert(
            expected_event == ImplementationFinalized { impl_hash: implementation_data.impl_hash },
            'ImplementationFinalized Error'
        );
    // TODO check the new impl hash.
    // TODO check the new impl is final.
    }

    #[test]
    #[should_panic(expected: ('GOVERNOR_ONLY', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_not_governor() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_nonfinal_replaceable_data(:governor_address);

        // Invoke not as a governor.
        let not_governor_address = starknet::contract_address_const::<11>();
        starknet::testing::set_contract_address(not_governor_address);
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('FINALIZED', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_replace_to_already_final() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data(:governor_address);

        // Set the contract address to be of the token bridge, so we can call the internal 
        // finalize() function on the replaceable contract state.
        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::InternalFunctions::finalize(ref token_bridge_state);

        starknet::testing::set_contract_address(governor_address);
        token_bridge.replace_to(:implementation_data);
    }

    #[test]
    #[should_panic(expected: ('UNKNOWN_IMPLEMENTATION', 'ENTRYPOINT_FAILED', ))]
    #[available_gas(30000000)]
    fn test_replaceability_unknown_implementation() {
        // Set governor parameters.
        let governor_address = starknet::contract_address_const::<10>();
        starknet::testing::set_contract_address(governor_address);

        // Deploy the token bridge.
        let token_bridge_address = deploy_token_bridge(:governor_address);
        let token_bridge = get_replaceable(:token_bridge_address);

        let implementation_data = get_dummy_final_replaceable_data(:governor_address);

        // Calling replace_to without previously adding the implementation.
        starknet::testing::set_contract_address(governor_address);
        token_bridge.replace_to(:implementation_data);
    }
}
