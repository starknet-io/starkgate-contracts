#[cfg(test)]
mod lockable_token_test {
    use src::mintable_lock_interface::ITokenLockDispatcherTrait;
    use starknet::{ContractAddress, get_contract_address};
    use src::test_utils::test_utils::{
        deploy_lockable_token, initial_owner, get_erc20_token, caller, deploy_votes_lock,
        get_token_lock_interface, pop_and_deserialize_last_event, not_caller,
        set_contract_address_as_not_caller, set_contract_address_as_caller,
        get_mintable_lock_interface, get_erc20_votes_token, arbitrary_user,
        deploy_lock_and_votes_tokens
    };
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use src::mintable_lock_interface::{
        ILockingContract, ILockingContractDispatcher, ILockingContractDispatcherTrait,
        ILockAndDelegate, ILockAndDelegateDispatcher, ILockAndDelegateDispatcherTrait, Locked,
        Unlocked, IMintableLockDispatcher, IMintableLockDispatcherTrait
    };
    use openzeppelin::governance::utils::interfaces::votes::{
        IVotesDispatcher, IVotesDispatcherTrait
    };
    use openzeppelin::token::erc20::presets::erc20_votes_lock::ERC20VotesLock::{Event};
    use starknet::testing::set_contract_address;
    use starknet::contract_address_const;


    #[derive(Copy, Drop, PartialEq)]
    enum VotesTokenFunction {
        Lock,
        Unlock,
        LockAndDelegate,
    }


    fn _erc20_votes_lock() -> ContractAddress {
        let locked_token = starknet::contract_address_const::<20>();
        deploy_votes_lock(:locked_token)
    }


    // Verifies that the difference between after and before is as expected.
    fn check_change_post_action(
        after: u256, before: u256, expected_diff: u256, after_is_greater: bool, err_code: felt252
    ) {
        if after_is_greater {
            assert(after - before == expected_diff, :err_code);
        } else {
            assert(before - after == expected_diff, :err_code);
        }
    }


    fn lock_and_verify_total_supply_and_balance(
        votes_lock_token: ContractAddress, lockable_token: ContractAddress, amount: u256
    ) {
        apply_action_and_verify(
            :votes_lock_token,
            :lockable_token,
            :amount,
            action: VotesTokenFunction::Lock,
            delegatee: Option::None
        );
    }

    fn lock_delegate_and_verify_total_supply_and_balance(
        votes_lock_token: ContractAddress,
        lockable_token: ContractAddress,
        amount: u256,
        delegatee: ContractAddress
    ) {
        apply_action_and_verify(
            :votes_lock_token,
            :lockable_token,
            :amount,
            action: VotesTokenFunction::LockAndDelegate,
            delegatee: Option::Some(delegatee),
        );
    }

    fn unlock_and_verify_total_supply_and_balance(
        votes_lock_token: ContractAddress, lockable_token: ContractAddress, amount: u256
    ) {
        apply_action_and_verify(
            :votes_lock_token,
            :lockable_token,
            :amount,
            action: VotesTokenFunction::Unlock,
            delegatee: Option::None
        );
    }

    fn votes_token_action(
        votes_lock_token: ContractAddress,
        lockable_token: ContractAddress,
        amount: u256,
        action: VotesTokenFunction,
        delegatee: Option<ContractAddress>,
    ) {
        let token_lock_interface = get_token_lock_interface(l2_token: votes_lock_token);
        match action {
            // Lock the token and verify that the event was emitted.
            VotesTokenFunction::Lock => {
                token_lock_interface.lock(:amount);
                let emitted_event = pop_and_deserialize_last_event(address: votes_lock_token);
                assert(
                    emitted_event == Event::Locked(
                        Locked { account: get_contract_address(), amount }
                    ),
                    'LOCK_ERROR'
                );
            },
            VotesTokenFunction::Unlock => {
                // Unlock the token and verify that the event was emitted.
                token_lock_interface.unlock(:amount);
                let emitted_event = pop_and_deserialize_last_event(address: votes_lock_token);
                assert(
                    emitted_event == Event::Unlocked(
                        Unlocked { account: get_contract_address(), amount }
                    ),
                    'UNLOCK_ERROR'
                );
            },
            VotesTokenFunction::LockAndDelegate => {
                let delegate_account = delegatee.unwrap();
                // Lock and delegate from caller to delegatee.
                let mintable_lock_interface = get_mintable_lock_interface(
                    l2_token: votes_lock_token
                );
                set_contract_address(address: lockable_token);
                mintable_lock_interface
                    .permissioned_lock_and_delegate(
                        account: caller(), delegatee: delegate_account, amount: amount
                    );
                set_contract_address(address: caller());
            }
        }
    }

    // Handles lock, lock_and_delegate and unlock. For all three cases, the function verifies that
    // the events and that the balances and the supply are updated as expected.
    fn apply_action_and_verify(
        votes_lock_token: ContractAddress,
        lockable_token: ContractAddress,
        amount: u256,
        action: VotesTokenFunction,
        delegatee: Option<ContractAddress>,
    ) {
        // Get the erc20 interface for both tokens.
        let erc20_lockable_interface = get_erc20_token(l2_token: lockable_token);
        let erc20_votes_lock_interface = get_erc20_token(l2_token: votes_lock_token);

        let lockable_balance_before = erc20_lockable_interface
            .balance_of(account: get_contract_address());
        let lockable_supply_before = erc20_lockable_interface.total_supply();

        let votes_balance_before = erc20_votes_lock_interface
            .balance_of(account: get_contract_address());
        let votes_supply_before = erc20_votes_lock_interface.total_supply();

        let lockable_balance_of_votes_token_before = erc20_lockable_interface
            .balance_of(account: votes_lock_token);

        votes_token_action(:votes_lock_token, :lockable_token, :amount, :action, :delegatee);

        // Store if the action is unlock or not.
        let is_unlock = (action == VotesTokenFunction::Unlock);

        // Verify that the total supply of the lockable token was not changed.
        check_change_post_action(
            after: erc20_lockable_interface.total_supply(),
            before: lockable_supply_before,
            expected_diff: 0,
            after_is_greater: !is_unlock,
            err_code: 'LOCKABLE_SUPPLY_SHOULDNT_CHANGE'
        );

        // Verify that the total supply of the votes token increased/decreased by amount, when
        // locking/unlocking accordingly.
        check_change_post_action(
            after: erc20_votes_lock_interface.total_supply(),
            before: votes_supply_before,
            expected_diff: amount,
            after_is_greater: !is_unlock,
            err_code: 'BAD_AMOUNT_OF_MINTED_TOKENS'
        );

        // Verify that the current contract address' balance of the lockable token was
        // decreased/increased by amount, when locking/unlocking accordingly.
        // NOTE: since in lock, the balance is decreased after_is_greater equals to unlock.
        check_change_post_action(
            after: erc20_lockable_interface.balance_of(account: get_contract_address()),
            before: lockable_balance_before,
            expected_diff: amount,
            after_is_greater: is_unlock,
            err_code: 'BAD_LOCKABLE_BALANCE'
        );

        // Verify that the current contract address' balance of the votes token was
        // increased/decreased by amount, when locking/unlocking accordingly.
        check_change_post_action(
            after: erc20_votes_lock_interface.balance_of(account: get_contract_address()),
            before: votes_balance_before,
            expected_diff: amount,
            after_is_greater: !is_unlock,
            err_code: 'BAD_VOTES_BALANCE'
        );

        // Verify that votes_lock_token balance of the lockable token was increased/decreased by
        // amount, when locking/unlocking accordingly.
        check_change_post_action(
            after: erc20_lockable_interface.balance_of(account: votes_lock_token),
            before: lockable_balance_of_votes_token_before,
            expected_diff: amount,
            after_is_greater: !is_unlock,
            err_code: 'VOTES_WRONG_BALANCE_OF_LOCKABLE'
        );
    }

    fn increase_allowance(
        erc20_token: ContractAddress, spender: ContractAddress, added_value: u256
    ) {
        let erc20_lockable_interface = get_erc20_token(l2_token: erc20_token);
        erc20_lockable_interface.increase_allowance(:spender, :added_value);
    }

    fn transfer(erc20_token: ContractAddress, recipient: ContractAddress, amount: u256) {
        let erc20_token_interface = get_erc20_token(l2_token: erc20_token);
        erc20_token_interface.transfer(:recipient, :amount);
    }

    fn assert_voting_power(
        votes_lock_token: ContractAddress, account: ContractAddress, expected_amount: u256
    ) {
        let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
        assert(
            erc20_votes_token_interface.get_votes(:account) == expected_amount,
            'VOTES_ERROR_OF_DELEGATEE'
        );
    }

    fn account_delgate_to_himself(votes_lock_token: ContractAddress, account: ContractAddress) {
        let orig = get_contract_address();

        set_contract_address(address: account);
        let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
        erc20_votes_token_interface.delegate(delegatee: account);

        set_contract_address(address: orig);
    }


    #[test]
    #[available_gas(30000000)]
    fn test_deploy_votes_lock_token() {
        _erc20_votes_lock();
    }

    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_votes_lock() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
    }

    // This test is very similar to test_happy_flow_votes_lock. It locks the same amount of tokens
    // but in two consecutive locks.
    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_votes_two_locks() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
    }


    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED',))]
    fn test_not_enough_allowance_votes_lock() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );

        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount + 1
        );
    }


    // Tests where there are two consecutive locks. The first one should succeed and the second one
    // should fail.
    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED',))]
    fn test_not_enough_allowance_votes_two_locks() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );

        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2 + 1
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_votes_unlock() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 1000_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );

        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
    }

    // This test is very similar to test_happy_flow_votes_unlock. It unlocks the same amount of
    // tokens but in two consecutive unlocks.
    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_votes_two_unlocks() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );

        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
    }

    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED',))]
    fn test_unlock_more_than_locked() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 1000_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount + 1
        );
    }

    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED',))]
    fn test_over_unlock_in_two_parts() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2
        );
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount / 2 + 1
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_votes_lock_unlock_two_accounts() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let locked_amount = 1000_u256;
        let funds_of_first_account = 100_u256;
        let funds_of_second_account = locked_amount - funds_of_first_account;
        transfer(
            erc20_token: lockable_token, recipient: not_caller(), amount: funds_of_second_account
        );

        increase_allowance(
            erc20_token: lockable_token,
            spender: votes_lock_token,
            added_value: funds_of_first_account
        );

        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: funds_of_first_account
        );

        set_contract_address_as_not_caller();
        increase_allowance(
            erc20_token: lockable_token,
            spender: votes_lock_token,
            added_value: funds_of_second_account
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: funds_of_second_account
        );
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: funds_of_second_account
        );

        set_contract_address_as_caller();
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: funds_of_first_account
        );
    }


    // Flow of the test:
    // 1. User A locks lockable (`votes_lock_token` are minted)
    // 2. User A transfer `votes_lock_token` to user B.
    // 3. User B unlock (`votes_lock_token` are burned).
    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_lock_transfer_and_unlock() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );
        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
        transfer(erc20_token: votes_lock_token, recipient: not_caller(), amount: locked_amount);
        set_contract_address_as_not_caller();
        unlock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_permissioned_lock_and_delegate() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let delegatee = arbitrary_user();
        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        // Caller lock and delegate to delgatee.
        lock_delegate_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount, :delegatee
        );

        let erc20_votes_lock_interface = get_erc20_token(l2_token: votes_lock_token);
        let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);

        let delegatee = arbitrary_user();
        assert(
            erc20_votes_lock_interface.balance_of(account: delegatee) == 0,
            'ERROR_VOTES_TOKEN_BAL_NO_CALLER'
        );

        assert(
            erc20_votes_token_interface.delegates(account: caller()) == delegatee,
            'UNEXPECTED_DELEGATEE'
        );
        assert(
            erc20_votes_token_interface.get_votes(account: delegatee) == locked_amount,
            'VOTES_ERROR_AFTER_LOCK_N_DELEGA'
        );
    }

    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('INVALID_CALLER', 'ENTRYPOINT_FAILED',))]
    fn test_invalid_caller_permissioned_lock_and_delegate() {
        let (_, votes_lock_token) = deploy_lock_and_votes_tokens(initial_supply: 1000_u256);

        // The caller to permissioned_lock_and_delegate should be the lockable token. Since this
        // isn't the case, the call should fail.
        let not_lockable_contract = contract_address_const::<987>();
        set_contract_address(address: not_lockable_contract);
        let mintable_lock_interface = get_mintable_lock_interface(l2_token: votes_lock_token);
        mintable_lock_interface
            .permissioned_lock_and_delegate(account: caller(), delegatee: not_caller(), amount: 1);
    }

    // Flow of the test:
    // 1. User A locks `first_locked_amount` of `lockable_token`.
    // 2. User A transfer `votes_lock_token` to user B.
    // 3. User B delegates to himself (voting power accordingly).
    // 4. User A performs lock_and_delegate of anohter amounts (voting power increased).
    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_transfer_and_permissioned_and_delegate() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let delegatee = arbitrary_user();
        let first_locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: first_locked_amount
        );
        lock_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: first_locked_amount
        );

        transfer(erc20_token: votes_lock_token, recipient: delegatee, amount: first_locked_amount);

        assert_voting_power(:votes_lock_token, account: delegatee, expected_amount: 0);
        account_delgate_to_himself(:votes_lock_token, account: delegatee);
        assert_voting_power(
            :votes_lock_token, account: delegatee, expected_amount: first_locked_amount
        );

        let second_locked_amount = 200_u256;
        increase_allowance(
            erc20_token: lockable_token,
            spender: votes_lock_token,
            added_value: second_locked_amount
        );
        // Caller lock and delegate to delgatee.
        lock_delegate_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: second_locked_amount, :delegatee
        );
        assert_voting_power(
            :votes_lock_token,
            account: delegatee,
            expected_amount: first_locked_amount + second_locked_amount
        );
    }

    #[test]
    #[available_gas(30000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED',))]
    fn test_overdraft_permissioned_lock_and_delegate() {
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: 1000_u256
        );

        let delegatee = arbitrary_user();
        let locked_amount = 100_u256;
        increase_allowance(
            erc20_token: lockable_token, spender: votes_lock_token, added_value: locked_amount
        );
        lock_delegate_and_verify_total_supply_and_balance(
            :votes_lock_token, :lockable_token, amount: locked_amount + 1, :delegatee
        );
    }
}
