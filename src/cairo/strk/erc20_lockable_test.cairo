#[cfg(test)]
mod lockable_token_test {
    use starknet::ContractAddress;
    use integer::BoundedInt;
    use serde::Serde;
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use src::test_utils::test_utils::{
        initial_owner, caller, permitted_minter, get_erc20_token, set_caller_as_upgrade_governor,
        arbitrary_address, arbitrary_user, deploy_lock_and_votes_tokens,
        deploy_lock_and_votes_tokens_with_owner, get_locking_contract_interface, not_caller,
        deploy_account, get_erc20_votes_token, deploy_lockable_token,
        get_lock_and_delegate_interface
    };
    use src::mintable_lock_interface::{
        ILockingContract, ILockingContractDispatcher, ILockingContractDispatcherTrait,
        ILockAndDelegate, ILockAndDelegateDispatcher, ILockAndDelegateDispatcherTrait
    };

    // The account address is taken into account in eip-712 signature.
    // So, if it changes, signature fixture are invalidated and have to be replaced.
    // This fixture helps identifying this right away.
    fn expected_account_address() -> ContractAddress {
        starknet::contract_address_const::<
            0x64197b5827b3c126bfa2dafc484f220b7a5d8d35ebabfdcffa6370b262fa643
        >()
    }

    fn deploy_testing_lockable_token() -> ContractAddress {
        let initial_owner = initial_owner();
        deploy_lockable_token(:initial_owner, initial_supply: 1000_u256)
    }
    use openzeppelin::governance::utils::interfaces::votes::{
        IVotesDispatcher, IVotesDispatcherTrait
    };

    fn set_locking_contract(lockable_token: ContractAddress, locking_contract: ContractAddress) {
        let locking_contract_interface = get_locking_contract_interface(l2_token: lockable_token);
        locking_contract_interface.set_locking_contract(:locking_contract);
    }

    // Sets the caller as the upgrade governor and then set the locking contract.
    fn prepare_and_set_locking_contract(
        lockable_token: ContractAddress, locking_contract: ContractAddress
    ) {
        set_caller_as_upgrade_governor(replaceable_address: lockable_token);
        set_locking_contract(:lockable_token, :locking_contract);
    }


    fn lock_and_delegate(
        lockable_token: ContractAddress, delegatee: ContractAddress, amount: u256
    ) {
        let lock_and_delegate_interface = get_lock_and_delegate_interface(l2_token: lockable_token);
        lock_and_delegate_interface.lock_and_delegate(:delegatee, :amount);
    }

    fn lock_and_delegate_by_sig(
        lockable_token: ContractAddress,
        account: ContractAddress,
        delegatee: ContractAddress,
        amount: u256,
        nonce: felt252,
        expiry: u64,
        signature: Array<felt252>
    ) {
        let lock_and_delegate_interface = get_lock_and_delegate_interface(l2_token: lockable_token);
        lock_and_delegate_interface
            .lock_and_delegate_by_sig(:account, :delegatee, :amount, :nonce, :expiry, :signature);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_deploy_lockable_token() {
        deploy_testing_lockable_token();
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_failed_set_locking_contract_not_upgrade_governor() {
        let lockable_token = deploy_testing_lockable_token();
        set_locking_contract(:lockable_token, locking_contract: arbitrary_address());
    }

    #[test]
    #[should_panic(expected: ('ZERO_ADDRESS', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_failed_set_locking_contract_zero_address() {
        let lockable_token = deploy_testing_lockable_token();
        let zero_locking_contract_address = starknet::contract_address_const::<0>();
        prepare_and_set_locking_contract(
            :lockable_token, locking_contract: zero_locking_contract_address
        );
    }

    #[test]
    #[should_panic(expected: ('LOCKING_CONTRACT_ALREADY_SET', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_failed_set_locking_contract_already_set() {
        let lockable_token = deploy_testing_lockable_token();

        prepare_and_set_locking_contract(:lockable_token, locking_contract: arbitrary_address());
        let another_locking_contract_address = starknet::contract_address_const::<20>();
        set_locking_contract(:lockable_token, locking_contract: another_locking_contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_set_and_get_locking_contact() {
        let lockable_token = deploy_testing_lockable_token();

        set_caller_as_upgrade_governor(replaceable_address: lockable_token);
        let locking_contract_interface = get_locking_contract_interface(l2_token: lockable_token);
        locking_contract_interface.set_locking_contract(locking_contract: arbitrary_address());
        let locking_contract_result = locking_contract_interface.get_locking_contract();
        assert(locking_contract_result == arbitrary_address(), 'UNEXPECTED_LOCKING_CONTRACT');
    }

    #[test]
    #[should_panic(expected: ('LOCKING_CONTRACT_NOT_SET', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_failed_lock_and_delegate_not_set() {
        let lockable_token = deploy_testing_lockable_token();
        let delegatee = arbitrary_user();
        lock_and_delegate(:lockable_token, :delegatee, amount: 100_u256);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_lock_and_delegate() {
        let initial_supply = 1000_u256;
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

        // Store votes_lock_token as the locking contract.
        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        let erc20_lockable_interface = get_erc20_token(l2_token: lockable_token);
        let erc20_votes_lock_interface = get_erc20_token(l2_token: votes_lock_token);

        // Verify that the caller has balance of initial_supply for the locked token and zero
        // balance of the votes token.
        assert(
            erc20_lockable_interface.balance_of(account: caller()) == initial_supply,
            'BAD_BALANCE_TEST_SETUP'
        );
        assert(
            erc20_votes_lock_interface.balance_of(account: caller()) == 0, 'BAD_BALANCE_TEST_SETUP'
        );

        let delegatee = arbitrary_user();
        lock_and_delegate(:lockable_token, :delegatee, amount: initial_supply);

        // Verify that the caller has balance of initial_supply for the votes token and zero balance
        // of the locked token.
        assert(erc20_lockable_interface.balance_of(account: caller()) == 0, 'UNEXPECTED_BALANCE');
        assert(
            erc20_votes_lock_interface.balance_of(account: caller()) == initial_supply,
            'UNEXPECTED_BALANCE'
        );
        // Verify that the votes_lock_token has balance of initial_supply for the locked token.
        assert(
            erc20_lockable_interface.balance_of(account: votes_lock_token) == initial_supply,
            'UNEXPECTED_BALANCE'
        );

        let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
        assert(
            erc20_votes_token_interface.delegates(account: caller()) == delegatee, 'DELEGATE_FAILED'
        );
    }

    #[test]
    #[available_gas(30000000)]
    #[should_panic(
        expected: (
            'u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED',
        )
    )]
    fn test_lock_and_delegate_underflow() {
        let initial_supply = 1000_u256;
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

        // Store votes_lock_token as the locking contract.
        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Caller try to delegate more than his supply.
        let delegatee = arbitrary_user();
        lock_and_delegate(:lockable_token, :delegatee, amount: initial_supply + 1);
    }

    // Tests that the lock_and_delegate function can handle BoundedInt::max.
    #[test]
    #[available_gas(30000000)]
    fn test_lock_and_delegate_max_bounded_int() {
        let initial_supply = BoundedInt::max();
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(:initial_supply);

        // Store votes_lock_token as the locking contract.
        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Caller try to delegate all his balance which is BoundedInt::max.
        let delegatee = arbitrary_user();
        lock_and_delegate(:lockable_token, :delegatee, amount: BoundedInt::max());
    }

    fn get_initial_supply() -> u256 {
        1000_u256
    }

    // Signifanct other of the number 0x52656d6f20746865206d657263696c657373 .
    fn get_account_public_key() -> felt252 {
        0x890324441c151f11fc60046f5db3014faf0e7ec427797bead23e279e0604a2
    }

    fn get_delegation_sig() -> Array<felt252> {
        array![
            0x341ec075225ded67c66680e4226e1c4ad261074df0434af59720b0117086e17,
            0x767ef0ec64bde505563961eba498fffef6b55201e0e4db7d6e2e51ee7d3a6fd
        ]
    }

    fn get_delegatee() -> starknet::ContractAddress {
        starknet::contract_address_const::<10>()
    }

    fn get_expiry() -> u64 {
        123456_u64
    }

    fn get_nonce() -> felt252 {
        32
    }

    fn get_chain_id() -> felt252 {
        'SN_GOERLI'
    }

    #[test]
    #[available_gas(30000000)]
    fn test_happy_flow_lock_and_delegate_by_sig() {
        // Set chain id.
        starknet::testing::set_chain_id(chain_id: get_chain_id());

        // Account setup.
        let account_address = deploy_account(public_key: get_account_public_key());
        assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

        // Lockable token contract setup.
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
            initial_owner: account_address, initial_supply: get_initial_supply()
        );

        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Set as not caller, to validate caller address isn't improperly used.
        starknet::testing::set_caller_address(address: not_caller());

        lock_and_delegate_by_sig(
            lockable_token: lockable_token,
            account: account_address,
            delegatee: get_delegatee(),
            amount: get_initial_supply(),
            nonce: get_nonce(),
            expiry: get_expiry(),
            signature: get_delegation_sig()
        );

        // Validate delegation success.
        let erc20_votes_token_interface = get_erc20_votes_token(l2_token: votes_lock_token);
        assert(
            erc20_votes_token_interface.delegates(account: account_address) == get_delegatee(),
            'DELEGATE_FAILED'
        );
    }


    #[test]
    #[should_panic(expected: ('SIGNATURE_EXPIRED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_lock_and_delegate_by_sig_expired() {
        starknet::testing::set_block_timestamp(get_expiry() + 1);

        // Lockable token contract setup.
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens(
            initial_supply: get_initial_supply()
        );

        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Invoke delegation with signature.
        lock_and_delegate_by_sig(
            lockable_token: lockable_token,
            account: caller(),
            delegatee: get_delegatee(),
            amount: get_initial_supply(),
            nonce: get_nonce(),
            expiry: get_expiry(),
            signature: get_delegation_sig()
        );
    }

    #[test]
    #[should_panic(expected: ('SIGNED_REQUEST_ALREADY_USED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_lock_and_delegate_by_sig_request_replay() {
        // Set chain id.
        starknet::testing::set_chain_id(chain_id: get_chain_id());

        // Account setup.
        let account_address = deploy_account(public_key: get_account_public_key());
        assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

        // Lockable token contract setup.
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
            initial_owner: account_address, initial_supply: get_initial_supply()
        );

        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Invoke delegation with signature.
        lock_and_delegate_by_sig(
            lockable_token: lockable_token,
            account: account_address,
            delegatee: get_delegatee(),
            amount: get_initial_supply(),
            nonce: get_nonce(),
            expiry: 123456,
            signature: get_delegation_sig()
        );

        // Invoke delegation with signature again.
        lock_and_delegate_by_sig(
            lockable_token: lockable_token,
            account: account_address,
            delegatee: get_delegatee(),
            amount: get_initial_supply(),
            nonce: get_nonce(),
            expiry: get_expiry(),
            signature: get_delegation_sig()
        );
    }

    #[test]
    #[should_panic(expected: ('SIGNATURE_VALIDATION_FAILED', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_lock_and_delegate_by_sig_invalid_sig() {
        // Set chain id.
        starknet::testing::set_chain_id(chain_id: get_chain_id());

        // Account setup.
        let account_address = deploy_account(public_key: get_account_public_key());
        assert(account_address == expected_account_address(), 'ACCOUNT_ADDRESS_CHANGED');

        // Lockable token contract setup.
        let (lockable_token, votes_lock_token) = deploy_lock_and_votes_tokens_with_owner(
            initial_owner: account_address, initial_supply: get_initial_supply()
        );

        prepare_and_set_locking_contract(:lockable_token, locking_contract: votes_lock_token);

        // Set as not caller, to validate caller address isn't improperly used.
        starknet::testing::set_caller_address(address: not_caller());

        // Invoke delegation with signature with modified data that invalidates the signature.
        lock_and_delegate_by_sig(
            lockable_token: lockable_token,
            account: account_address,
            delegatee: get_delegatee(),
            amount: get_initial_supply(),
            nonce: get_nonce() + 1,
            expiry: get_expiry(),
            signature: get_delegation_sig()
        );
    }
}
