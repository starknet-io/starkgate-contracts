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

    use starknet::class_hash::{
        ClassHash, Felt252TryIntoClassHash, class_hash_const, ClassHashZeroable
    };
    use starknet::{
        contract_address_const, ContractAddress, EthAddress, ContractAddressIntoFelt252,
        get_block_timestamp
    };
    use starknet::syscalls::deploy_syscall;

    use super::super::permissioned_erc20::PermissionedERC20;
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::stub_msg_receiver::StubMsgReceiver;
    use super::super::token_bridge::TokenBridge;
    use super::super::token_bridge::TokenBridge::{
        Event, L1BridgeSet, Erc20ClassHashStored, DeployHandled, WithdrawInitiated, DepositHandled,
        DepositWithMessageHandled, ImplementationAdded, ImplementationRemoved,
        ImplementationReplaced, ImplementationFinalized, RoleGranted, RoleRevoked, RoleAdminChanged,
        AppRoleAdminAdded, AppRoleAdminRemoved, UpgradeGovernorAdded, UpgradeGovernorRemoved,
        GovernanceAdminAdded, GovernanceAdminRemoved, AppGovernorAdded, AppGovernorRemoved,
        OperatorAdded, OperatorRemoved, TokenAdminAdded, TokenAdminRemoved, LimitWithdrawalOff,
        LimitWithdrawalOn, SECONDS_IN_DAY, DAILY_WITHDRAW_LIMIT_PCT
    };
    use super::super::roles_interface::{
        APP_GOVERNOR, APP_ROLE_ADMIN, GOVERNANCE_ADMIN, OPERATOR, TOKEN_ADMIN, UPGRADE_GOVERNOR
    };


    use super::super::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use super::super::test_utils::test_utils::{
        caller, not_caller, initial_owner, permitted_minter, set_contract_address_as_caller,
        set_contract_address_as_not_caller, get_erc20_token, deploy_l2_token,
        pop_and_deserialize_last_event, pop_last_k_events, deserialize_event, arbitrary_event,
        assert_role_granted_event, assert_role_revoked_event, validate_empty_event_queue, get_roles,
        get_replaceable, get_access_control, set_caller_as_upgrade_governor, deploy_token_bridge,
        DEFAULT_UPGRADE_DELAY
    };


    use super::super::replaceability_interface::{
        EICData, ImplementationData, IReplaceable, IReplaceableDispatcher,
        IReplaceableDispatcherTrait
    };
    use super::super::roles_interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use super::super::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };

    const EXPECTED_CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const EXPECTED_CONTRACT_VERSION: felt252 = 2;


    const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
    const DEFAULT_L1_RECIPIENT: felt252 = 12;
    const DEFAULT_L1_TOKEN_ETH_ADDRESS: felt252 = 1337;
    const DEFAULT_DEPOSITOR_ETH_ADDRESS: felt252 = 7;

    const NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 6;

    const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
    const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;

    const NAME: felt252 = 'NAME';
    const SYMBOL: felt252 = 'SYMBOL';
    const DECIMALS: u8 = 18;


    // TODO - Delete this once this can be a const.
    fn default_amount() -> u256 {
        u256 { low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH }
    }

    fn get_default_l1_addresses() -> (EthAddress, EthAddress, EthAddress) {
        (
            EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS },
            EthAddress { address: DEFAULT_L1_TOKEN_ETH_ADDRESS },
            EthAddress { address: DEFAULT_L1_RECIPIENT }
        )
    }

    fn set_caller_as_app_role_admin_app_governor(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_app_governor(account: caller());
    }


    fn deploy_stub_msg_receiver() -> ContractAddress {
        // Set the constructor calldata.
        let mut calldata = array![];

        // Deploy the contract.
        let (stub_msg_receiver_address, _) = deploy_syscall(
            StubMsgReceiver::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false
        )
            .unwrap();
        stub_msg_receiver_address
    }
    fn get_token_bridge(token_bridge_address: ContractAddress) -> ITokenBridgeDispatcher {
        ITokenBridgeDispatcher { contract_address: token_bridge_address }
    }


    // Deploys the token bridge and sets the caller as the app governer (and as App Role Admin).
    // Returns the token bridge.
    fn deploy_and_prepare() -> ITokenBridgeDispatcher {
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);
        get_token_bridge(:token_bridge_address)
    }

    fn prepare_bridge_for_deploy_token(
        token_bridge_address: ContractAddress, l1_bridge_address: EthAddress
    ) {
        // Get the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set the l1 bridge address in the token bridge.
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Set ERC20 class hash.
        let erc20_class_hash = PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap();
        token_bridge.set_erc20_class_hash(erc20_class_hash);
    }

    // Prepares the bridge for deploying a new token and then deploys it.
    fn deploy_new_token(
        token_bridge_address: ContractAddress,
        l1_bridge_address: EthAddress,
        l1_token_address: EthAddress
    ) {
        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);
        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Deploy token contract.
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_enrollment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token_address: l1_token_address,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
    }

    // Prepares the bridge for deploying a new token and then deploys it and do a first deposit into
    // it.
    fn deploy_new_token_and_deposit(
        token_bridge_address: ContractAddress,
        l1_bridge_address: EthAddress,
        l1_token_address: EthAddress,
        l2_recipient: ContractAddress,
        amount_to_deposit: u256
    ) {
        deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token_address);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l2_recipient,
            token: l1_token_address,
            amount: amount_to_deposit
        );
    }


    // Prepares the bridge for deploying a new token, then deploys it and do a first deposit with
    // message into it.
    fn deploy_new_token_and_deposit_with_message(
        token_bridge_address: ContractAddress,
        l1_bridge_address: EthAddress,
        l1_token_address: EthAddress,
        l2_recipient: ContractAddress,
        amount_to_deposit: u256,
        depositor: EthAddress,
        message: Span<felt252>
    ) {
        deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token_address);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit_with_message(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l2_recipient,
            token: l1_token_address,
            amount: amount_to_deposit,
            :depositor,
            :message
        );
    }

    fn assert_l2_account_balance(
        token_bridge_address: ContractAddress,
        l1_token_address: EthAddress,
        owner: ContractAddress,
        amount: u256
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token_address = token_bridge.get_l2_token_address(l1_token_address);
        let erc20_token = get_erc20_token(:l2_token_address);
        assert(erc20_token.balance_of(owner) == amount, 'MISMATCHING_L2_ACCOUNT_BALANCE');
    }


    fn withdraw_and_validate(
        token_bridge_address: ContractAddress,
        withdraw_from: ContractAddress,
        l1_recipient: EthAddress,
        l1_token_address: EthAddress,
        amount_to_withdraw: u256,
        amount_before_withdraw: u256
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);

        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);
        let erc20_token = get_erc20_token(:l2_token_address);
        let total_supply = erc20_token.total_supply();

        starknet::testing::set_contract_address(address: withdraw_from);
        token_bridge
            .initiate_withdraw(:l1_recipient, token: l1_token_address, amount: amount_to_withdraw);
        // Validate the new balance and total supply.
        assert(
            erc20_token.balance_of(withdraw_from) == amount_before_withdraw - amount_to_withdraw,
            'INIT_WITHDRAW_BALANCE_ERROR'
        );
        assert(
            erc20_token.total_supply() == total_supply - amount_to_withdraw,
            'INIT_WITHDRAW_SUPPLY_ERROR'
        );
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::WithdrawInitiated(
                WithdrawInitiated {
                    l1_recipient: l1_recipient,
                    token: l1_token_address,
                    amount: amount_to_withdraw,
                    caller_address: withdraw_from
                }
            ),
            'WithdrawInitiated Error'
        );
    }

    // Set the limit of the withdrawal amount and make sure that the event is emitted.
    fn apply_withdrawal_limit(
        token_bridge_address: ContractAddress, l1_token_address: EthAddress, applied_state: bool
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);
        set_contract_address_as_caller();
        token_bridge.apply_withdrawal_limit(token: l1_token_address, :applied_state);
        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        if (applied_state) {
            assert(
                emitted_event == Event::LimitWithdrawalOn(LimitWithdrawalOn { l1_token_address }),
                'LimitWithdrawalOn Error'
            );
        } else {
            assert(
                emitted_event == Event::LimitWithdrawalOff(LimitWithdrawalOff { l1_token_address }),
                'LimitWithdrawalOff Error'
            );
        };
    }

    fn get_max_allowed_withdrawal_amount(
        token_bridge_address: ContractAddress, l1_token_address: EthAddress
    ) -> u256 {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);
        TokenBridge::InternalFunctions::get_daily_withdrawal_limit(:l2_token_address)
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
            emitted_event == Event::L1BridgeSet(
                L1BridgeSet { l1_bridge_address: l1_bridge_address }
            ),
            'L1BridgeSet Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED',))]
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
    #[should_panic(expected: ('L1_BRIDGE_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED',))]
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
    #[should_panic(expected: ('ZERO_L1_BRIDGE_ADDRESS', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_zero_address_set_l1_bridge() {
        let token_bridge = deploy_and_prepare();

        // Set the l1 bridge with a 0 address.
        token_bridge.set_l1_bridge(l1_bridge_address: EthAddress { address: 0 });
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_erc20_class_hash() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        let erc20_class_hash = PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap();

        // Set the l2 contract address on the token bridge.
        token_bridge.set_erc20_class_hash(:erc20_class_hash);
        assert(token_bridge.get_erc20_class_hash() == erc20_class_hash, 'erc20 mismatch.');

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Erc20ClassHashStored {
                previous_hash: ClassHashZeroable::zero(), erc20_class_hash: erc20_class_hash
            },
            'Erc20ClassHashStored Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_missing_role_set_erc20_class_hash() {
        let token_bridge = deploy_and_prepare();
        let erc20_class_hash = PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap();

        // Set the erc20_class_hash not as the caller.
        set_contract_address_as_not_caller();
        token_bridge.set_erc20_class_hash(:erc20_class_hash);
    }


    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw (set the caller to be the initial_owner).
        let amount_to_withdraw = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            :amount_to_withdraw,
            amount_before_withdraw: amount_to_deposit
        );
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is exactly the
    // maximum allowed amount. This is done in a single withdrawal.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw_with_limits_one_withdrawal() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        // Withdraw exactly the maximum allowed amount.
        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: max_amount_allowed_to_withdraw,
            amount_before_withdraw: amount_to_deposit
        );
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is exactly the
    // maximum allowed amount. This is done in two withdrawals.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw_with_limits_two_withdrawals() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;
        // Withdraw exactly half of the allowed amount.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit
        );

        // Withdraw exactly the allowed amount that left.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: max_amount_allowed_to_withdraw - first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit - first_withdrawal_amount
        );
    }

    // Tests the case where after the first legal withdrawal, limit withdrawal is turned off and
    // then on again. The amount that is withdrawn during the time that the withdrawal limit is on,
    // is exactly the maximum allowed amount.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw_with_and_without_limits() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: false);

        // Withdraw above the allowed amount - legal because there is no withdrawal limit.
        let amount_to_withdraw_no_limit = max_amount_allowed_to_withdraw + 1;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: amount_to_withdraw_no_limit,
            amount_before_withdraw: amount_to_deposit - first_withdrawal_amount
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        // Withdraw exactly the allowed amount that left.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: max_amount_allowed_to_withdraw - first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit
                - first_withdrawal_amount
                - amount_to_withdraw_no_limit
        );
    }

    // Tests the case where after the first legal withdrawal, limit withdrawal is turned off and
    // then on again. The amount that is withdrawn during the time that the withdrawal limit is on,
    // is above the maximum allowed amount.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_withdraw_with_and_without_limits() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;

        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_withdraw(
                :l1_recipient, token: l1_token_address, amount: first_withdrawal_amount
            );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: false);

        // Withdraw above the allowed amount - legal because there is no withdrawal limit.
        starknet::testing::set_contract_address(address: l2_recipient);
        token_bridge
            .initiate_withdraw(
                :l1_recipient, token: l1_token_address, amount: max_amount_allowed_to_withdraw + 1
            );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        // Withdraw above the allowed amount that left.
        starknet::testing::set_contract_address(address: l2_recipient);
        token_bridge
            .initiate_withdraw(
                :l1_recipient,
                token: l1_token_address,
                amount: max_amount_allowed_to_withdraw - first_withdrawal_amount + 1
            );
    }

    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different days, where each withdrawal is exactly the maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw_with_limits_different_days() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        // Withdraw exactly the allowed amount.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: max_amount_allowed_to_withdraw,
            amount_before_withdraw: amount_to_deposit
        );

        // Withdraw again after 1 day a legal amount.
        let current_time = get_block_timestamp();
        starknet::testing::set_block_timestamp(block_timestamp: SECONDS_IN_DAY + current_time);

        let new_max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: new_max_amount_allowed_to_withdraw,
            amount_before_withdraw: amount_to_deposit - max_amount_allowed_to_withdraw
        );
    }

    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different times but in the same day, where the sum of both withdrawal's amount is exactly the
    // maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw_with_limits_same_day_differnet_time() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit
        );

        // Withdraw again at the same day a legal amount for this day.
        let current_time = get_block_timestamp();
        // Get another timestamp at the same day.
        let mut different_time_same_day = current_time + 1000;
        if (different_time_same_day / 86400 != current_time / 86400) {
            different_time_same_day = current_time - 1000;
        }
        starknet::testing::set_block_timestamp(block_timestamp: different_time_same_day);

        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: max_amount_allowed_to_withdraw - first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit - first_withdrawal_amount
        );
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is above the
    // maximum allowed amount. This is done in a single withdrawal.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_withdraw_limit_exceeded_one_withdrawal() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );

        // Withdraw above the allowed amount.
        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_withdraw(
                :l1_recipient, token: l1_token_address, amount: max_amount_allowed_to_withdraw + 1
            );
    }


    // Tests the case where the withdrawal limit is on and the withdrawal amount is above the
    // maximum allowed amount. This is done in a two withdrawals.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_withdraw_limit_exceeded_two_withdrawals() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        apply_withdrawal_limit(:token_bridge_address, :l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;

        // Withdraw above the allowed amount in the second withdrawal.
        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_withdraw(
                :l1_recipient, token: l1_token_address, amount: first_withdrawal_amount
            );
        token_bridge
            .initiate_withdraw(
                :l1_recipient,
                token: l1_token_address,
                amount: max_amount_allowed_to_withdraw - first_withdrawal_amount + 1
            );
    }


    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different times but in the same day, where the sum of both withdrawal's amount is above the
    // maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_withdraw_limit_exceeded_same_day_different_time() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        // Limit the withdrawal amount.
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_contract_address_as_caller();
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: true);

        let max_amount_allowed_to_withdraw = get_max_allowed_withdrawal_amount(
            :token_bridge_address, :l1_token_address
        );
        let first_withdrawal_amount = max_amount_allowed_to_withdraw / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token_address,
            amount_to_withdraw: first_withdrawal_amount,
            amount_before_withdraw: amount_to_deposit
        );

        let current_time = get_block_timestamp();
        // Get another timestamp at the same day.
        let mut different_time_same_day = current_time + 1000;
        if (different_time_same_day / 86400 != current_time / 86400) {
            different_time_same_day = current_time - 1000;
        }
        // Withdraw again at the same day. This time withdraw an amount that exceeds the limit.
        starknet::testing::set_block_timestamp(block_timestamp: different_time_same_day);
        token_bridge
            .initiate_withdraw(
                :l1_recipient,
                token: l1_token_address,
                amount: max_amount_allowed_to_withdraw - first_withdrawal_amount + 1
            );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_apply_withdrawal_limit_not_app_governor() {
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Use an arbitrary l1 token address.
        let l1_token_address = EthAddress { address: DEFAULT_L1_TOKEN_ETH_ADDRESS };
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: true);
    }


    #[test]
    #[should_panic(expected: ('TOKEN_NOT_IN_BRIDGE', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_apply_withdrawal_limit_token_not_in_bridge() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge = deploy_and_prepare();

        // Use an arbitrary l1 token address (which was not deployed).
        let l1_token_address = EthAddress { address: DEFAULT_L1_TOKEN_ETH_ADDRESS };
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: true);
    }


    // Tests that in case the withdrawal limit is on/off and there is another attempt to start/stop
    // the limit accordingly, the value is not changed and no event is being emitted.
    #[test]
    #[available_gas(30000000)]
    fn test_token_limited_unchanged_no_event() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);

        // Empty the event queue.
        pop_last_k_events(address: token_bridge_address, k: 1);

        // The default is that the withdrawal limit is off; hence, stopping the limit again should
        // not emit an event or change the value.
        set_contract_address_as_caller();
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: false);
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l2_token_address) == BoundedInt::max(),
            'withdraw_limited_apply Error'
        );
        validate_empty_event_queue(address: token_bridge_address);

        set_contract_address_as_caller();
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: true);

        // Empty the event queue.
        pop_last_k_events(address: token_bridge_address, k: 1);

        // The withdrawal limit is on; hence, starting the limit again should not emit an event or
        // change the value.
        token_bridge.apply_withdrawal_limit(token: l1_token_address, applied_state: true);
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l2_token_address) != BoundedInt::max(),
            'withdraw_limited_apply Error'
        );
        validate_empty_event_queue(address: token_bridge_address);
    }


    // Tests that get_daily_withdrawal_limit returns the right amount.
    #[test]
    #[available_gas(30000000)]
    fn test_get_daily_withdrawal_limit() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );
        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);
        let mut expected_result = amount_to_deposit * DAILY_WITHDRAW_LIMIT_PCT / 100;
        assert(
            TokenBridge::InternalFunctions::get_daily_withdrawal_limit(
                :l2_token_address
            ) == expected_result,
            'daily_withdrawal_limit Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_token_enrollment() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        token_bridge.set_l1_bridge(:l1_bridge_address);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::L1BridgeSet(
                L1BridgeSet { l1_bridge_address: l1_bridge_address }
            ),
            'L1BridgeSet Error'
        );

        // Set ERC20 class hash.
        let erc20_class_hash = PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap();
        token_bridge.set_erc20_class_hash(erc20_class_hash);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::Erc20ClassHashStored(
                Erc20ClassHashStored {
                    erc20_class_hash: erc20_class_hash, previous_hash: ClassHashZeroable::zero()
                }
            ),
            'Erc20ClassHashStored Error'
        );

        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_enrollment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token_address: l1_token_address,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );

        let l2_token_address = token_bridge.get_l2_token_address(:l1_token_address);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DeployHandled(
                DeployHandled {
                    l1_token_address: l1_token_address,
                    name: NAME,
                    symbol: SYMBOL,
                    decimals: DECIMALS
                }
            ),
            'DeployHandled Error'
        );
        assert(
            token_bridge.get_l1_token_address(:l2_token_address) == l1_token_address,
            'token address mismatch'
        );
    }

    #[test]
    #[should_panic(expected: ('TOKEN_ALREADY_EXISTS',))]
    #[available_gas(30000000)]
    fn test_handle_token_enrollment_twice() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        token_bridge.set_l1_bridge(:l1_bridge_address);

        // Set ERC20 class hash.
        let erc20_class_hash = PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap();
        token_bridge.set_erc20_class_hash(erc20_class_hash);

        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        // Enroll the token twice.
        let name = 'TOKEN_NAME';
        let symbol = 'TOKEN_SYMBOL';
        let decimals = 6_u8;
        TokenBridge::handle_token_enrollment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token_address: l1_token_address,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
        TokenBridge::handle_token_enrollment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token_address: l1_token_address,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
    #[available_gas(30000000)]
    fn test_non_l1_token_message_handle_token_enrollment() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        let l1_not_bridge_address = EthAddress { address: NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        TokenBridge::handle_token_enrollment(
            ref token_bridge_state,
            from_address: l1_not_bridge_address.into(),
            l1_token_address: l1_token_address,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
    }


    #[test]
    #[should_panic(expected: ('ZERO_WITHDRAWAL', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_zero_amount_initiate_withdraw() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw.
        let token_bridge = get_token_bridge(:token_bridge_address);
        let amount = u256 { low: 0, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_withdraw(:l1_recipient, token: l1_token_address, :amount);
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_FUNDS', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_excessive_amount_initiate_withdraw() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token_address, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw.
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_withdraw(
                :l1_recipient, token: l1_token_address, amount: amount_to_deposit + 1
            );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_deposit() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let first_amount = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            :l2_recipient,
            amount_to_deposit: first_amount
        );

        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Simulate an "handle_deposit" l1 message.
        let deposit_amount_low: u128 = 17;
        let second_amount = u256 { low: deposit_amount_low, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l2_recipient,
            token: l1_token_address,
            amount: second_amount
        );
        let total_amount = first_amount + second_amount;
        assert_l2_account_balance(
            :token_bridge_address, :l1_token_address, owner: l2_recipient, amount: total_amount
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DepositHandled(
                DepositHandled {
                    l2_recipient: l2_recipient, token: l1_token_address, amount: second_amount
                }
            ),
            'DepositHandled Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_deposit_with_message() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        // Create a dummy contract that will be the account to deposit to.
        let stub_msg_receiver_address = deploy_stub_msg_receiver();

        let amount_to_deposit = default_amount();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Create a dummy message.
        let mut message = array![];
        7.serialize(ref message);
        let message_span = message.span();

        deploy_new_token_and_deposit_with_message(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            l2_recipient: stub_msg_receiver_address,
            :amount_to_deposit,
            depositor: depositor,
            message: message_span
        );

        assert_l2_account_balance(
            :token_bridge_address,
            :l1_token_address,
            owner: stub_msg_receiver_address,
            amount: amount_to_deposit
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DepositWithMessageHandled(
                DepositWithMessageHandled {
                    l2_recipient: stub_msg_receiver_address,
                    token: l1_token_address,
                    amount: amount_to_deposit,
                    message: message_span
                }
            ),
            'DepositWithMessageHandled Error'
        );
    }


    #[test]
    #[should_panic(expected: ('DEPOSIT_REJECTED',))]
    #[available_gas(30000000)]
    // Tests the case where on receive returns false. In this case, the deposit should fail.
    fn test_handle_deposit_with_message_on_receive_return_false() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();

        let amount_to_deposit = default_amount();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Create a dummy contract that will be the account to deposit to.
        let stub_msg_receiver_address = deploy_stub_msg_receiver();

        // Create a dummy message.
        let mut message = array![];
        'RETURN FALSE'.serialize(ref message);
        let message_span = message.span();

        deploy_new_token_and_deposit_with_message(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            l2_recipient: stub_msg_receiver_address,
            :amount_to_deposit,
            depositor: depositor,
            message: message_span
        );
    }

    #[test]
    #[should_panic(expected: ('ON_RECEIVE_FAILED',))]
    #[available_gas(30000000)]
    // Tests the case where on receive fails. In this case, the deposit should fail.
    fn test_handle_deposit_with_message_fail_on_receive() {
        // Create an arbitrary l1 bridge and token address.
        let (l1_bridge_address, l1_token_address, _) = get_default_l1_addresses();

        // Create a dummy contract that will be the account to deposit to.
        let stub_msg_receiver_address = deploy_stub_msg_receiver();

        let token_bridge_address = deploy_token_bridge();

        let amount_to_deposit = default_amount();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Create a dummy message.
        let mut message = array![];
        'ASSERT'.serialize(ref message);
        let message_span = message.span();

        deploy_new_token_and_deposit_with_message(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token_address,
            l2_recipient: stub_msg_receiver_address,
            :amount_to_deposit,
            depositor: depositor,
            message: message_span
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
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

        // Set the l1 bridge address in the token bridge.
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
            l2_recipient: initial_owner,
            token: l1_bridge_address,
            amount: default_amount()
        );
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
        let arbitrary_role = 'ARBITRARY';
        let admin_of_arbitrary_role = 'ADMIN_OF_ARBITRARY';

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
    #[should_panic(expected: ('INVALID_ACCOUNT_ADDRESS',))]
    #[available_gas(30000000)]
    fn test_grant_role_and_emit_zero_account() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let arbitrary_role = 'ARBITRARY';
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
        let arbitrary_role = 'ARBITRARY';
        let admin_of_arbitrary_role = 'ADMIN_OF_ARBITRARY';

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
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: APP_GOVERNOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: APP_ROLE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: GOVERNANCE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: OPERATOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: TOKEN_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
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
    #[should_panic(expected: ('ROLES_ALREADY_INITIALIZED',))]
    #[available_gas(30000000)]
    fn test_initialize_roles_already_set() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        starknet::testing::set_caller_address(address: not_caller());
        TokenBridge::InternalFunctions::_initialize_roles(ref token_bridge_state);
        TokenBridge::InternalFunctions::_initialize_roles(ref token_bridge_state);
    }

    // Validates is_app_governor function, under the assumption that register_app_role_admin and
    // register_app_governor, function as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_app_governor(account: arbitrary_account);

        assert(token_bridge_roles.is_app_governor(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_app_role_admin function, under the assumption that register_app_role_admin,
    // functions as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: arbitrary_account);

        assert(
            token_bridge_roles.is_app_role_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_governance_admin function, under the assumption that register_governance_admin,
    // functions as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_governance_admin(account: arbitrary_account);

        assert(
            token_bridge_roles.is_governance_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_operator_admin function, under the assumption that register_app_role_admin and
    // register_operator, function as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_operator(account: arbitrary_account);

        assert(token_bridge_roles.is_operator(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_token_admin function, under the assumption that register_app_role_admin and
    // register_token_admin, function as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_token_admin(account: arbitrary_account);

        assert(token_bridge_roles.is_token_admin(account: arbitrary_account), 'Role not granted');
    }
    // Validates is_upgrade_governor function, under the assumption that register_upgrade_governor,
    // functions as expected.
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
        let token_bridge_roles = get_roles(:token_bridge_address);
        token_bridge_roles.register_upgrade_governor(account: arbitrary_account);

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
            role_revoked_emitted_event == Event::RoleRevoked(
                RoleRevoked {
                    role: UPGRADE_GOVERNOR, account: arbitrary_account, sender: arbitrary_account
                }
            ),
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
    #[should_panic(expected: ('GOV_ADMIN_CANNOT_SELF_REMOVE', 'ENTRYPOINT_FAILED',))]
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
    #[should_panic(expected: ('ONLY_APP_GOVERNOR',))]
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
    #[should_panic(expected: ('ONLY_APP_ROLE_ADMIN',))]
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
    #[should_panic(expected: ('ONLY_GOVERNANCE_ADMIN',))]
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
    #[should_panic(expected: ('ONLY_OPERATOR',))]
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
    #[should_panic(expected: ('ONLY_TOKEN_ADMIN',))]
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
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR',))]
    #[available_gas(30000000)]
    fn test_only_upgrade_governor_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::InternalFunctions::only_upgrade_governor(@token_bridge_state);
    }
}
