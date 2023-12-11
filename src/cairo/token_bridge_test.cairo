#[cfg(test)]
mod token_bridge_test {
    use integer::BoundedInt;

    use starknet::class_hash::{ClassHash, ClassHashZeroable};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        contract_address_const, ContractAddress, EthAddress, ContractAddressIntoFelt252,
        get_block_timestamp, get_contract_address
    };
    use starknet::syscalls::deploy_syscall;

    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::token_test_setup_interface::{
        ITokenTestSetupDispatcher, ITokenTestSetupDispatcherTrait
    };
    use super::super::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait, RoleAdminChanged, RoleRevoked,
    };
    use super::super::token_bridge::TokenBridge;
    use super::super::token_bridge::TokenBridge::{
        Event, L1BridgeSet, Erc20ClassHashStored, DeployHandled, WithdrawInitiated, DepositHandled,
        deposit_handled, DepositWithMessageHandled, withdraw_initiated,
    };
    use super::super::roles_interface::{
        IRolesDispatcher, IRolesDispatcherTrait, APP_GOVERNOR, APP_ROLE_ADMIN, GOVERNANCE_ADMIN,
        OPERATOR, TOKEN_ADMIN, UPGRADE_GOVERNOR, AppGovernorAdded, AppGovernorRemoved,
        AppRoleAdminAdded, AppRoleAdminRemoved, GovernanceAdminAdded, GovernanceAdminRemoved,
        OperatorAdded, OperatorRemoved, TokenAdminAdded, TokenAdminRemoved, UpgradeGovernorAdded,
        UpgradeGovernorRemoved,
    };

    use super::super::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use super::super::token_bridge_admin_interface::{
        ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait
    };
    use super::super::test_utils::test_utils::{
        caller, not_caller, initial_owner, permitted_minter, set_contract_address_as_caller,
        get_erc20_token, deploy_l2_token, pop_and_deserialize_last_event, pop_last_k_events,
        deserialize_event, arbitrary_event, assert_role_granted_event, assert_role_revoked_event,
        validate_empty_event_queue, get_roles, get_access_control, deploy_token_bridge,
        stock_erc20_class_hash, votes_erc20_class_hash, deploy_stub_msg_receiver,
        withdraw_and_validate, deploy_upgraded_legacy_bridge, get_token_bridge,
        get_token_bridge_admin, _get_daily_withdrawal_limit, disable_withdrawal_limit,
        enable_withdrawal_limit, set_caller_as_app_role_admin_app_governor, default_amount,
        get_default_l1_addresses, prepare_bridge_for_deploy_token, deploy_new_token,
        deploy_new_token_and_deposit, DEFAULT_INITIAL_SUPPLY_HIGH, DEFAULT_L1_BRIDGE_ETH_ADDRESS,
        DEFAULT_INITIAL_SUPPLY_LOW, NAME, SYMBOL, DECIMALS
    };


    use super::super::replaceability_interface::{
        EICData, ImplementationData, IReplaceable, IReplaceableDispatcher,
        IReplaceableDispatcherTrait
    };

    const EXPECTED_CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const EXPECTED_CONTRACT_VERSION: felt252 = 2;

    const DEFAULT_DEPOSITOR_ETH_ADDRESS: felt252 = 7;

    const NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 6;


    // Prepares the bridge for deploying a new token, then deploys it and do a first deposit with
    // message into it.
    fn deploy_new_token_and_deposit_with_message(
        token_bridge_address: ContractAddress,
        l1_bridge_address: EthAddress,
        l1_token: EthAddress,
        l2_recipient: ContractAddress,
        amount_to_deposit: u256,
        depositor: EthAddress,
        message: Span<felt252>
    ) {
        deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit_with_message(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l1_token,
            :depositor,
            :l2_recipient,
            amount: amount_to_deposit,
            :message
        );
    }

    fn assert_l2_account_balance(
        token_bridge_address: ContractAddress,
        l1_token: EthAddress,
        owner: ContractAddress,
        amount: u256
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token = token_bridge.get_l2_token(:l1_token);
        let erc20_token = get_erc20_token(:l2_token);
        assert(erc20_token.balance_of(owner) == amount, 'MISMATCHING_L2_ACCOUNT_BALANCE');
    }


    #[test]
    #[available_gas(30000000)]
    fn test_identity_and_version() {
        let token_bridge = get_token_bridge(token_bridge_address: deploy_token_bridge());

        // Verify identity and version.
        assert(
            token_bridge.get_identity() == EXPECTED_CONTRACT_IDENTITY, 'Contract identity mismatch.'
        );
        assert(
            token_bridge.get_version() == EXPECTED_CONTRACT_VERSION, 'Contract version mismatch.'
        );
    }


    // Negatively test that legacy `initiate_withdraw` can't succeed if an l2_token is not
    // configured (i.e if it isn't an upgraded legacy bridge it will fail).
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('L2_TOKEN_NOT_SET', 'ENTRYPOINT_FAILED',))]
    fn test_initiate_withdraw_token_not_set() {
        let (_, _, l1_recipient) = get_default_l1_addresses();

        let token_bridge = get_token_bridge(token_bridge_address: deploy_token_bridge());

        starknet::testing::set_contract_address(address: initial_owner());
        token_bridge.initiate_withdraw(:l1_recipient, amount: 1);
    }


    // Tests legacy bridge `initiate_withdraw` where legacy `l2_token` variable mismatches the post
    // upgrade `l2_l1_token_map` & `l1_l2_token_map` mappings.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('L1_L2_TOKEN_MISMATCH', 'ENTRYPOINT_FAILED',))]
    fn test_initiate_withdraw_token_mismatch() {
        let (_, l1_token, l1_recipient) = get_default_l1_addresses();

        let l2_recipient = initial_owner();
        let token_bridge_address = deploy_upgraded_legacy_bridge(
            :l1_token, :l2_recipient, token_mismatch: true
        );
        let token_bridge = get_token_bridge(:token_bridge_address);

        token_bridge.initiate_withdraw(:l1_recipient, amount: 1);
    }


    // Tests the initiate_withdraw function for a leacy token bridge.
    // In order to do so, a dummy contract is deployed. The dummy contract allows to set the
    // l2_token in the storage (among few other storage varaibles). After that, this contract is
    // being replaced to the token bridge and the initiate_withdraw function is being called.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_withdraw() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
        let l2_recipient = initial_owner();

        let token_bridge_address = deploy_upgraded_legacy_bridge(
            :l1_token, :l2_recipient, token_mismatch: false
        );

        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

        let token_bridge = get_token_bridge(:token_bridge_address);

        // Call initiate_withdraw and make sure that both events are being emitted (the legacy one
        // and the new one).
        let amount = 1;
        starknet::testing::set_contract_address(address: l2_recipient);
        token_bridge.initiate_withdraw(:l1_recipient, :amount);
        let events = pop_last_k_events(address: token_bridge_address, k: 2);
        let withdraw_legacy_event = deserialize_event(*events.at(1));
        assert(
            withdraw_legacy_event == Event::withdraw_initiated(
                withdraw_initiated {
                    l1_recipient: l1_recipient, amount: amount, caller_address: l2_recipient
                }
            ),
            'withdraw_initiated Error'
        );
        let withdraw_new_event = deserialize_event(*events.at(0));
        assert(
            withdraw_new_event == Event::WithdrawInitiated(
                WithdrawInitiated {
                    l1_token: l1_token,
                    l1_recipient: l1_recipient,
                    amount: amount,
                    caller_address: l2_recipient
                }
            ),
            'WithdrawInitiated Error'
        );
    }

    // Negatively test that legacy `handle_deposit` can't succeed if an l2_token is not
    // configured (i.e if it isn't an upgraded legacy bridge it will fail).
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('TOKEN_CONFIG_MISMATCH',))]
    fn test_failed_handle_deposit_token_not_set() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
        let token_bridge_address = deploy_token_bridge();
        internal_handle_depoist(
            :token_bridge_address, :l1_bridge_address, l2_recipient: initial_owner(), amount: 1
        );
    }


    // Tests legacy bridge `handle_deposit` where legacy `l2_token` variable mismatches the post
    // upgrade `l2_l1_token_map` & `l1_l2_token_map` mappings.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('L1_L2_TOKEN_MISMATCH',))]
    fn test_handle_deposit_token_mismatch() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();

        let l2_recipient = initial_owner();
        let token_bridge_address = deploy_upgraded_legacy_bridge(
            :l1_token, :l2_recipient, token_mismatch: true
        );
        internal_handle_depoist(
            :token_bridge_address, :l1_bridge_address, l2_recipient: initial_owner(), amount: 1
        );
    }


    // Tests an upgraded bridge happy path of the legacy handle_deposit.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_deposit() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        let l2_recipient = initial_owner();
        let token_bridge_address = deploy_upgraded_legacy_bridge(
            :l1_token, :l2_recipient, token_mismatch: false
        );

        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

        // Call handle_deposit and make sure that both events are being emitted (the legacy one
        // and the new one).
        let amount = 1;
        internal_handle_depoist(:token_bridge_address, :l1_bridge_address, :l2_recipient, :amount);

        let deposit_events = pop_last_k_events(address: token_bridge_address, k: 2);
        let deposit_legacy_event = deserialize_event(*deposit_events.at(1));
        assert(
            deposit_legacy_event == Event::deposit_handled(
                deposit_handled { account: l2_recipient, amount: amount }
            ),
            'deposit_handled Error'
        );
        let deposit_new_event = deserialize_event(*deposit_events.at(0));
        assert(
            deposit_new_event == Event::DepositHandled(
                DepositHandled { l1_token: l1_token, amount: amount, l2_recipient: l2_recipient }
            ),
            'DepositHandled Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };
        let token_bridge_address = deploy_token_bridge();

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw (set the caller to be the initial_owner).
        let amount_to_withdraw = u256 { low: 700, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            :amount_to_withdraw,
        );
    }


    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('INVALID_RECIPIENT', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_token_withdraw_invalid_recipient() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        // Invalid recipient.
        let l1_recipient = EthAddress { address: 0 };

        let token_bridge_address = deploy_token_bridge();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );

        // Should panic because the recipient is invalid.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: amount_to_deposit,
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_get_remaining_withdrawal_quota() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // The token does not exist; hence, there is no withdrawal limit applied. Therefore, the
        // quota is max.
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l1_token) == BoundedInt::max(),
            'remaining_withdraw_quota Error'
        );

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );
        // By default, the withdrawal limit is off; hence, the quota is max.
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l1_token) == BoundedInt::max(),
            'remaining_withdraw_quota Error'
        );

        // Apply withdrawal limit. Therefore, the quota is the daily withdrawal limit.
        enable_withdrawal_limit(:token_bridge_address, :l1_token);
        assert(
            token_bridge
                .get_remaining_withdrawal_quota(
                    :l1_token
                ) == _get_daily_withdrawal_limit(:token_bridge_address, :l1_token),
            'remaining_withdraw_quota Error'
        );

        // Withdraw some of the funds and verifies that the quota is being updated accordingly.
        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let amount_to_withdraw = daily_withdrawal_limit / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            :amount_to_withdraw,
        );
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l1_token) == daily_withdrawal_limit
                - amount_to_withdraw,
            'remaining_withdraw_quota Error'
        );

        // Stop the withdrawal limit. Therefore, the quota is max.
        disable_withdrawal_limit(:token_bridge_address, :l1_token);
        assert(
            token_bridge.get_remaining_withdrawal_quota(:l1_token) == BoundedInt::max(),
            'remaining_withdraw_quota Error'
        );
    }


    // Tests that get_daily_withdrawal_limit returns the right amount.
    #[test]
    #[available_gas(30000000)]
    fn test_get_daily_withdrawal_limit() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );
        let l2_token = token_bridge.get_l2_token(:l1_token);
        starknet::testing::set_contract_address(address: token_bridge_address);
        let token_bridge_state = TokenBridge::contract_state_for_testing();
        let daily_withdrawal_limit_pct: u256 =
            TokenBridge::WithdrawalLimitInternal::get_daily_withdrawal_limit_pct(
            @token_bridge_state
        )
            .into();
        let expected_result = amount_to_deposit * daily_withdrawal_limit_pct / 100;
        assert(
            TokenBridge::WithdrawalLimitInternal::get_daily_withdrawal_limit(
                @token_bridge_state, :l2_token
            ) == expected_result,
            'daily_withdrawal_limit Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_erc20_handle_token_deployment() {
        // Set ERC20 class hash.
        let erc20_class_hash = stock_erc20_class_hash();
        _handle_token_deployment(:erc20_class_hash);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_votes_erc20_handle_token_deployment() {
        // Set Votes ERC20 class hash.
        let erc20_class_hash = votes_erc20_class_hash();
        _handle_token_deployment(:erc20_class_hash);
    }

    fn _handle_token_deployment(erc20_class_hash: ClassHash) {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge = get_token_bridge(:token_bridge_address);
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::L1BridgeSet(
                L1BridgeSet { l1_bridge_address: l1_bridge_address }
            ),
            'L1BridgeSet Error'
        );
        token_bridge_admin.set_l2_token_governance(caller());
        token_bridge_admin.set_erc20_class_hash(erc20_class_hash);
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
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l1_token,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );

        let l2_token = token_bridge.get_l2_token(:l1_token);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DeployHandled(
                DeployHandled { l1_token: l1_token, name: NAME, symbol: SYMBOL, decimals: DECIMALS }
            ),
            'DeployHandled Error'
        );
        assert(token_bridge.get_l1_token(:l2_token) == l1_token, 'token address mismatch');
    }


    fn internal_handle_depoist(
        token_bridge_address: ContractAddress,
        l1_bridge_address: EthAddress,
        l2_recipient: ContractAddress,
        amount: u256
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let orig = get_contract_address();
        starknet::testing::set_contract_address(address: token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_deposit(
            ref token_bridge_state, from_address: l1_bridge_address.into(), :l2_recipient, :amount
        );
        starknet::testing::set_contract_address(address: orig);
    }


    fn internal_deploy_token(
        token_bridge_address: ContractAddress, l1_bridge_address: EthAddress, l1_token: EthAddress
    ) -> ContractAddress {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let orig = get_contract_address();
        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token: l1_token,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
        starknet::testing::set_contract_address(address: orig);
        token_bridge.get_l2_token(:l1_token)
    }


    #[test]
    #[available_gas(30000000)]
    fn test_deployed_token_governance() {
        // Deploy l2 tokens and check it's governance.
        // Alternate the governance set on the bridge mid way.
        let l1_token1 = EthAddress { address: 1973 };
        let l1_token2 = EthAddress { address: 2023 };

        let erc20_class_hash = stock_erc20_class_hash();
        let (l1_bridge_address, _, _) = get_default_l1_addresses();
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);
        token_bridge_admin.set_erc20_class_hash(erc20_class_hash);

        token_bridge_admin.set_l2_token_governance(caller());
        let t1_roles = get_roles(
            internal_deploy_token(:token_bridge_address, :l1_bridge_address, l1_token: l1_token1)
        );

        token_bridge_admin.set_l2_token_governance(not_caller());
        let t2_roles = get_roles(
            internal_deploy_token(:token_bridge_address, :l1_bridge_address, l1_token: l1_token2)
        );

        assert(t1_roles.is_governance_admin(caller()), 'l2_token1 Role not granted');
        assert(!t1_roles.is_governance_admin(not_caller()), 'l2_token1 Wrong Role granted');
        assert(t2_roles.is_governance_admin(not_caller()), 'l2_token2 Role not granted');
        assert(!t2_roles.is_governance_admin(caller()), 'l2_token2 Wrong Role granted');
    }


    // Tests an attempt to deploy a token a onto an upgraded legacy bridge.
    // This is not allowed. Legacy bridges are blocked from deploying new tokens.
    #[test]
    #[should_panic(expected: ('DEPLOY_TOKEN_DISALLOWED',))]
    #[available_gas(30000000)]
    fn test_handle_token_deployment_legacy_bridge() {
        // Create an arbitrary l1 bridge, token address and l1 recipient.
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        let l2_recipient = initial_owner();
        let token_bridge_address = deploy_upgraded_legacy_bridge(
            :l1_token, :l2_recipient, token_mismatch: false
        );

        // Deploy the token.
        internal_deploy_token(:token_bridge_address, :l1_bridge_address, :l1_token);
    }

    #[test]
    #[should_panic(expected: ('TOKEN_ALREADY_EXISTS',))]
    #[available_gas(30000000)]
    fn test_handle_token_deployment_twice() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);

        token_bridge_admin.set_l2_token_governance(caller());
        token_bridge_admin.set_erc20_class_hash(stock_erc20_class_hash());

        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        // Deploy the token twice.
        let name = 'TOKEN_NAME';
        let symbol = 'TOKEN_SYMBOL';
        let decimals = 6_u8;
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token: l1_token,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            l1_token: l1_token,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
    #[available_gas(30000000)]
    fn test_non_l1_token_message_handle_token_deployment() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

        starknet::testing::set_contract_address(token_bridge_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        let l1_not_bridge_address = EthAddress { address: NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_not_bridge_address.into(),
            l1_token: l1_token,
            name: NAME,
            symbol: SYMBOL,
            decimals: DECIMALS
        );
    }


    #[test]
    #[should_panic(expected: ('ZERO_WITHDRAWAL', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_zero_amount_initiate_token_withdraw() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw.
        let token_bridge = get_token_bridge(:token_bridge_address);
        let amount = u256 { low: 0, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        token_bridge.initiate_token_withdraw(:l1_token, :l1_recipient, :amount);
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_FUNDS', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_excessive_amount_initiate_token_withdraw() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let amount_to_deposit = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            :amount_to_deposit
        );

        // Initiate withdraw.
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_token_withdraw(:l1_token, :l1_recipient, amount: amount_to_deposit + 1);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_token_deposit() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

        let token_bridge_address = deploy_token_bridge();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy a new token and deposit funds to this token.
        let l2_recipient = initial_owner();
        let first_amount = default_amount();
        deploy_new_token_and_deposit(
            :token_bridge_address,
            :l1_bridge_address,
            :l1_token,
            :depositor,
            :l2_recipient,
            amount_to_deposit: first_amount
        );

        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Simulate an "handle_token_deposit" l1 message.
        let deposit_amount_low: u128 = 17;
        let second_amount = u256 { low: deposit_amount_low, high: DEFAULT_INITIAL_SUPPLY_HIGH };
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_deposit(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l1_token,
            :depositor,
            :l2_recipient,
            amount: second_amount
        );
        let total_amount = first_amount + second_amount;
        assert_l2_account_balance(
            :token_bridge_address, :l1_token, owner: l2_recipient, amount: total_amount
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DepositHandled(
                DepositHandled {
                    l1_token: l1_token, l2_recipient: l2_recipient, amount: second_amount
                }
            ),
            'DepositHandled Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_handle_deposit_with_message() {
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

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
            :l1_token,
            l2_recipient: stub_msg_receiver_address,
            :amount_to_deposit,
            depositor: depositor,
            message: message_span
        );

        assert_l2_account_balance(
            :token_bridge_address,
            :l1_token,
            owner: stub_msg_receiver_address,
            amount: amount_to_deposit
        );

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::DepositWithMessageHandled(
                DepositWithMessageHandled {
                    depositor: depositor,
                    l1_token: l1_token,
                    l2_recipient: stub_msg_receiver_address,
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
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

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
            :l1_token,
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
        let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();

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
            :l1_token,
            l2_recipient: stub_msg_receiver_address,
            :amount_to_deposit,
            depositor: depositor,
            message: message_span
        );
    }

    #[test]
    #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
    #[available_gas(30000000)]
    fn test_non_l1_token_message_handle_token_deposit() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set an arbitrary l1 bridge address.
        let l1_bridge_address = EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };

        // Deploy token contract.
        let initial_owner = initial_owner();
        let l2_token = deploy_l2_token(
            :initial_owner,
            permitted_minter: token_bridge_address,
            initial_supply: u256 {
                low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH
            }
        );
        let erc20_token = get_erc20_token(:l2_token);

        token_bridge_admin.set_l1_bridge(:l1_bridge_address);

        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Simulate an "handle_token_deposit" l1 message from an incorrect Ethereum address.
        let l1_not_bridge_address = EthAddress { address: NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS };
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_deposit(
            ref token_bridge_state,
            from_address: l1_not_bridge_address.into(),
            l1_token: l1_bridge_address,
            :depositor,
            l2_recipient: initial_owner,
            amount: default_amount()
        );
    }
}
