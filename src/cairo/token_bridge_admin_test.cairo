#[cfg(test)]
mod token_bridge_admin_test {
    use starknet::class_hash::ClassHashZeroable;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{EthAddress, get_block_timestamp};

    use super::super::token_bridge::TokenBridge::{
        Event, L1BridgeSet, Erc20ClassHashStored, SECONDS_IN_DAY, L2TokenGovernanceChanged
    };


    use super::super::test_utils::test_utils::{
        caller, not_caller, initial_owner, set_contract_address_as_caller,
        set_contract_address_as_not_caller, pop_and_deserialize_last_event, get_token_bridge,
        get_token_bridge_admin, set_caller_as_app_role_admin_app_governor, deploy_token_bridge,
        stock_erc20_class_hash, get_default_l1_addresses, withdraw_and_validate,
        _get_daily_withdrawal_limit, enable_withdrawal_limit, disable_withdrawal_limit,
        default_amount, deploy_new_token_and_deposit,
    };

    use super::super::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use super::super::token_bridge_admin_interface::{
        ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait
    };

    const DEFAULT_DEPOSITOR_ETH_ADDRESS: felt252 = 7;
    // TODO change the name of deploy_and_prepare.

    // Deploys the token bridge and sets the caller as the App Governer (and as App Role Admin).
    // Returns the token bridge admin interface.
    fn deploy_and_prepare() -> ITokenBridgeAdminDispatcher {
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);
        get_token_bridge_admin(:token_bridge_address)
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_l1_bridge() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        let (l1_bridge_address, _, _) = get_default_l1_addresses();
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);

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
        let token_bridge_admin = deploy_and_prepare();

        let (l1_bridge_address, _, _) = get_default_l1_addresses();
        // Set the l1 bridge not as the App Governor.
        set_contract_address_as_not_caller();
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('L1_BRIDGE_ALREADY_INITIALIZED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_already_set_l1_bridge() {
        let token_bridge_admin = deploy_and_prepare();

        let (l1_bridge_address, _, _) = get_default_l1_addresses();
        // Set the l1 bridge twice.
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);
        token_bridge_admin.set_l1_bridge(:l1_bridge_address);
    }

    #[test]
    #[should_panic(expected: ('ZERO_L1_BRIDGE_ADDRESS', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_zero_address_set_l1_bridge() {
        let token_bridge_admin = deploy_and_prepare();

        // Set the l1 bridge with a 0 address.
        token_bridge_admin.set_l1_bridge(l1_bridge_address: EthAddress { address: 0 });
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_erc20_class_hash() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        // Set the l2 contract address on the token bridge.
        let erc20_class_hash = stock_erc20_class_hash();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        token_bridge_admin.set_erc20_class_hash(:erc20_class_hash);

        assert(token_bridge_admin.get_erc20_class_hash() == erc20_class_hash, 'erc20 mismatch.');

        // Validate event emission.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::Erc20ClassHashStored(
                Erc20ClassHashStored {
                    previous_hash: ClassHashZeroable::zero(), erc20_class_hash: erc20_class_hash
                }
            ),
            'Erc20ClassHashStored Error'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_l2_token_gov() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);
        let _caller = caller();
        let _not_caller = not_caller();

        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        token_bridge_admin.set_l2_token_governance(l2_token_governance: _not_caller);

        assert(
            token_bridge_admin.get_l2_token_governance() == _not_caller,
            'failed to set l2_token_gov'
        );
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::L2TokenGovernanceChanged(
                L2TokenGovernanceChanged {
                    previous_governance: ContractAddressZeroable::zero(),
                    new_governance: _not_caller
                }
            ),
            'L2TokenGovernanceChanged Error'
        );

        token_bridge_admin.set_l2_token_governance(l2_token_governance: _caller);
        assert(
            token_bridge_admin.get_l2_token_governance() == _caller, 'failed to set l2_token_gov'
        );

        // Validate event.
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::L2TokenGovernanceChanged(
                L2TokenGovernanceChanged {
                    previous_governance: _not_caller, new_governance: _caller
                }
            ),
            'L2TokenGovernanceChanged Error'
        );
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_missing_role_set_erc20_class_hash() {
        let token_bridge_admin = deploy_and_prepare();

        // Set the erc20_class_hash not as the caller.
        set_contract_address_as_not_caller();
        token_bridge_admin.set_erc20_class_hash(erc20_class_hash: stock_erc20_class_hash());
    }


    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_missing_role_set_l2_token_gov() {
        let token_bridge = deploy_and_prepare();

        // Set l2 token gov on the bridge not as the caller.
        set_contract_address_as_not_caller();
        token_bridge.set_l2_token_governance(caller());
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is exactly the
    // maximum allowed amount. This is done in a single withdrawal.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw_with_limits_one_withdrawal() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw exactly the maximum allowed amount.
        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: daily_withdrawal_limit,
        );
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is exactly the
    // maximum allowed amount. This is done in two withdrawals.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw_with_limits_two_withdrawals() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;
        // Withdraw exactly half of the allowed amount.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: first_withdrawal_amount,
        );

        // Withdraw exactly the allowed amount that left.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: daily_withdrawal_limit - first_withdrawal_amount,
        );
    }

    // Tests the case where after the first legal withdrawal, limit withdrawal is turned off and
    // then on again. The amount that is withdrawn during the time that the withdrawal limit is on,
    // is exactly the maximum allowed amount.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw_with_and_without_limits() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: first_withdrawal_amount,
        );

        disable_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw above the allowed amount - legal because there is no withdrawal limit.
        let amount_to_withdraw_no_limit = daily_withdrawal_limit + 1;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: amount_to_withdraw_no_limit,
        );

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw exactly the allowed amount that left.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: daily_withdrawal_limit - first_withdrawal_amount,
        );
    }

    // Tests the case where after the first legal withdrawal, limit withdrawal is turned off and
    // then on again. The amount that is withdrawn during the time that the withdrawal limit is on,
    // is above the maximum allowed amount.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_token_withdraw_with_and_without_limits() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;

        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_token_withdraw(:l1_token, :l1_recipient, amount: first_withdrawal_amount);

        disable_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw above the allowed amount - legal because there is no withdrawal limit.
        starknet::testing::set_contract_address(address: l2_recipient);
        token_bridge
            .initiate_token_withdraw(:l1_token, :l1_recipient, amount: daily_withdrawal_limit + 1);

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw above the allowed amount that left.
        starknet::testing::set_contract_address(address: l2_recipient);
        token_bridge
            .initiate_token_withdraw(
                :l1_token,
                :l1_recipient,
                amount: daily_withdrawal_limit - first_withdrawal_amount + 1
            );
    }

    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different days, where each withdrawal is exactly the maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw_with_limits_different_days() {
        let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
        let depositor = EthAddress { address: DEFAULT_DEPOSITOR_ETH_ADDRESS };
        let token_bridge_address = deploy_token_bridge();
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        token_bridge_admin.set_l2_token_governance(caller());

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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        // Withdraw exactly the allowed amount.
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: daily_withdrawal_limit,
        );

        // Withdraw again after 1 day a legal amount.
        let current_time = get_block_timestamp();
        starknet::testing::set_block_timestamp(block_timestamp: SECONDS_IN_DAY + current_time);

        let new_daily_withdrawal_limit = _get_daily_withdrawal_limit(
            :token_bridge_address, :l1_token
        );
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: new_daily_withdrawal_limit,
        );
    }


    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different times but in the same day, where the sum of both withdrawal's amount is exactly the
    // maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    fn test_successful_initiate_token_withdraw_with_limits_same_day_differnet_time() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: first_withdrawal_amount,
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
            :l1_token,
            amount_to_withdraw: daily_withdrawal_limit - first_withdrawal_amount,
        );
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is above the
    // maximum allowed amount. This is done in a single withdrawal.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_token_withdraw_limit_exceeded_one_withdrawal() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);

        // Withdraw above the allowed amount.
        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_token_withdraw(:l1_token, :l1_recipient, amount: daily_withdrawal_limit + 1);
    }

    // Tests the case where the withdrawal limit is on and the withdrawal amount is above the
    // maximum allowed amount. This is done in a two withdrawals.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_token_withdraw_limit_exceeded_two_withdrawals() {
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

        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;

        // Withdraw above the allowed amount in the second withdrawal.
        starknet::testing::set_contract_address(address: l2_recipient);
        let token_bridge = get_token_bridge(:token_bridge_address);
        token_bridge
            .initiate_token_withdraw(:l1_token, :l1_recipient, amount: first_withdrawal_amount);
        token_bridge
            .initiate_token_withdraw(
                :l1_token,
                :l1_recipient,
                amount: daily_withdrawal_limit - first_withdrawal_amount + 1
            );
    }

    // Tests the case where the withdrawal limit is on and there are two withdrawals in two
    // different times but in the same day, where the sum of both withdrawal's amount is above the
    // maximum allowed amount per that day.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('LIMIT_EXCEEDED', 'ENTRYPOINT_FAILED',))]
    fn test_failed_initiate_token_withdraw_limit_exceeded_same_day_different_time() {
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

        // Limit the withdrawal amount.
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_contract_address_as_caller();
        enable_withdrawal_limit(:token_bridge_address, :l1_token);

        let daily_withdrawal_limit = _get_daily_withdrawal_limit(:token_bridge_address, :l1_token);
        let first_withdrawal_amount = daily_withdrawal_limit / 2;
        withdraw_and_validate(
            :token_bridge_address,
            withdraw_from: l2_recipient,
            :l1_recipient,
            :l1_token,
            amount_to_withdraw: first_withdrawal_amount,
        );

        let current_time = get_block_timestamp();
        // Get another timestamp at the same day.
        let mut different_time_same_day = current_time + 1000;
        if (different_time_same_day / 86400 != current_time / 86400) {
            different_time_same_day = current_time - 1000;
        }
        // Withdraw again at the same day. This time withdraw an amount that exceeds the limit.
        let token_bridge = get_token_bridge(:token_bridge_address);
        starknet::testing::set_block_timestamp(block_timestamp: different_time_same_day);
        token_bridge
            .initiate_token_withdraw(
                :l1_token,
                :l1_recipient,
                amount: daily_withdrawal_limit - first_withdrawal_amount + 1
            );
    }

    #[test]
    #[should_panic(expected: ('ONLY_SECURITY_AGENT', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_enable_withdrawal_limit_not_security_agent() {
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);

        // Use an arbitrary l1 token address.
        let (_, l1_token, _) = get_default_l1_addresses();
        token_bridge_admin.enable_withdrawal_limit(:l1_token);
    }

    #[test]
    #[should_panic(expected: ('ONLY_SECURITY_ADMIN', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_disable_withdrawal_limit_not_security_admin() {
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);

        // Use an arbitrary l1 token address.
        let (_, l1_token, _) = get_default_l1_addresses();

        // Change the contract address since the caller is the security admin.
        set_contract_address_as_not_caller();
        token_bridge_admin.disable_withdrawal_limit(:l1_token);
    }

    #[test]
    #[should_panic(expected: ('TOKEN_NOT_IN_BRIDGE', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_enable_withdrawal_limit_token_not_in_bridge() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_admin = deploy_and_prepare();
        let token_bridge_address = token_bridge_admin.contract_address;

        // Use an arbitrary l1 token address (which was not deployed).
        let (_, l1_token, _) = get_default_l1_addresses();
        enable_withdrawal_limit(:token_bridge_address, :l1_token);
    }

    #[test]
    #[should_panic(expected: ('TOKEN_NOT_IN_BRIDGE', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_disable_withdrawal_limit_token_not_in_bridge() {
        // Deploy the token bridge and set the caller as the app governer (and as App Role Admin).
        let token_bridge_admin = deploy_and_prepare();
        let token_bridge_address = token_bridge_admin.contract_address;

        // Use an arbitrary l1 token address (which was not deployed).
        let (_, l1_token, _) = get_default_l1_addresses();
        disable_withdrawal_limit(:token_bridge_address, :l1_token);
    }
}
