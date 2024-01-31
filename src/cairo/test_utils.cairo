// A lean dummy account that implements `is_valid_signature`.
#[starknet::interface]
trait IsValidSignature<TState> {
    fn is_valid_signature(self: @TState, hash: felt252, signature: Array<felt252>) -> felt252;
}

#[starknet::contract]
mod TestAccount {
    use array::ArrayTrait;
    use array::SpanTrait;
    use ecdsa::check_ecdsa_signature;

    #[storage]
    struct Storage {
        public_key: felt252
    }

    #[constructor]
    fn constructor(ref self: ContractState, _public_key: felt252) {
        self.public_key.write(_public_key);
    }

    //
    // External
    //

    #[external(v0)]
    impl IsValidSignatureImpl of super::IsValidSignature<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>
        ) -> felt252 {
            if self._is_valid_signature(hash, signature.span()) {
                starknet::VALIDATED
            } else {
                0
            }
        }
    }

    //
    // Internal
    //

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _is_valid_signature(
            self: @ContractState, hash: felt252, signature: Span<felt252>
        ) -> bool {
            let valid_length = signature.len() == 2_u32;

            if valid_length {
                check_ecdsa_signature(
                    message_hash: hash,
                    public_key: self.public_key.read(),
                    signature_r: *signature.at(0_u32),
                    signature_s: *signature.at(1_u32)
                )
            } else {
                false
            }
        }
    }
}


#[cfg(test)]
mod test_utils {
    use array::ArrayTrait;
    use core::result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use serde::Serde;
    use starknet::{ContractAddress, EthAddress, syscalls::deploy_syscall, get_contract_address};
    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};
    use openzeppelin::token::erc20::presets::erc20_votes_lock::ERC20VotesLock;
    use openzeppelin::token::erc20_v070::erc20::ERC20;
    use src::strk::erc20_lockable::ERC20Lockable;

    use openzeppelin::governance::utils::interfaces::votes::{
        IVotesDispatcher, IVotesDispatcherTrait
    };
    use src::mintable_token_interface::{IMintableTokenDispatcher, IMintableTokenDispatcherTrait};
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use array::SpanTrait;
    use src::token_bridge::TokenBridge;
    use src::token_bridge::TokenBridge::{
        Event, WithdrawalLimitDisabled, WithdrawalLimitEnabled, WithdrawInitiated
    };

    use src::token_test_setup::TokenTestSetup;
    use src::token_test_setup_interface::{
        ITokenTestSetupDispatcher, ITokenTestSetupDispatcherTrait
    };
    use src::stub_msg_receiver::StubMsgReceiver;

    use src::token_bridge_interface::{ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait};
    use src::token_bridge_admin_interface::{
        ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait
    };

    use src::replaceability_interface::{
        IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait
    };
    use src::roles_interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use src::access_control_interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait, RoleId, RoleAdminChanged,
        RoleGranted, RoleRevoked,
    };
    use super::super::mintable_lock_interface::{
        ILockAndDelegateDispatcher, ILockAndDelegateDispatcherTrait, ILockingContractDispatcher,
        ILockingContractDispatcherTrait, ITokenLock, ITokenLockDispatcher,
        ITokenLockDispatcherTrait, IMintableLock, IMintableLockDispatcher,
        IMintableLockDispatcherTrait
    };

    use super::TestAccount;

    const DEFAULT_UPGRADE_DELAY: u64 = 12345;

    const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
    const DEFAULT_L1_RECIPIENT: felt252 = 12;
    const DEFAULT_L1_TOKEN_ETH_ADDRESS: felt252 = 1337;

    const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
    const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;

    const NAME: felt252 = 'NAME';
    const SYMBOL: felt252 = 'SYMBOL';
    const DECIMALS: u8 = 18;


    fn get_token_bridge(token_bridge_address: ContractAddress) -> ITokenBridgeDispatcher {
        ITokenBridgeDispatcher { contract_address: token_bridge_address }
    }

    fn get_token_bridge_admin(
        token_bridge_address: ContractAddress
    ) -> ITokenBridgeAdminDispatcher {
        ITokenBridgeAdminDispatcher { contract_address: token_bridge_address }
    }


    fn get_roles(contract_address: ContractAddress) -> IRolesDispatcher {
        IRolesDispatcher { contract_address: contract_address }
    }

    fn get_replaceable(replaceable_address: ContractAddress) -> IReplaceableDispatcher {
        IReplaceableDispatcher { contract_address: replaceable_address }
    }

    fn get_access_control(contract_address: ContractAddress) -> IAccessControlDispatcher {
        IAccessControlDispatcher { contract_address: contract_address }
    }


    fn get_erc20_token(l2_token: ContractAddress) -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: l2_token }
    }

    fn get_erc20_votes_token(l2_token: ContractAddress) -> IVotesDispatcher {
        IVotesDispatcher { contract_address: l2_token }
    }

    fn get_lock_and_delegate_interface(l2_token: ContractAddress) -> ILockAndDelegateDispatcher {
        ILockAndDelegateDispatcher { contract_address: l2_token }
    }

    fn get_locking_contract_interface(l2_token: ContractAddress) -> ILockingContractDispatcher {
        ILockingContractDispatcher { contract_address: l2_token }
    }

    fn get_token_lock_interface(l2_token: ContractAddress) -> ITokenLockDispatcher {
        ITokenLockDispatcher { contract_address: l2_token }
    }

    fn get_mintable_lock_interface(l2_token: ContractAddress) -> IMintableLockDispatcher {
        IMintableLockDispatcher { contract_address: l2_token }
    }

    fn arbitrary_address() -> ContractAddress {
        starknet::contract_address_const::<3563>()
    }


    fn arbitrary_user() -> ContractAddress {
        starknet::contract_address_const::<7171>()
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
        starknet::testing::set_contract_address(address: caller());
    }


    fn set_contract_address_as_not_caller() {
        starknet::testing::set_contract_address(address: not_caller());
    }


    fn arbitrary_event(
        role: RoleId, previous_admin_role: RoleId, new_admin_role: RoleId,
    ) -> Event {
        Event::RoleAdminChanged(RoleAdminChanged { role, previous_admin_role, new_admin_role })
    }

    // TODO - Delete this once this can be a const.
    fn default_amount() -> u256 {
        u256 { low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH }
    }

    fn lockable_erc20_class_hash() -> ClassHash {
        ERC20Lockable::TEST_CLASS_HASH.try_into().unwrap()
    }

    fn stock_erc20_class_hash() -> ClassHash {
        ERC20::TEST_CLASS_HASH.try_into().unwrap()
    }

    fn erc20_votes_lock_class_hash() -> ClassHash {
        ERC20VotesLock::TEST_CLASS_HASH.try_into().unwrap()
    }

    fn get_default_l1_addresses() -> (EthAddress, EthAddress, EthAddress) {
        (
            EthAddress { address: DEFAULT_L1_BRIDGE_ETH_ADDRESS },
            EthAddress { address: DEFAULT_L1_TOKEN_ETH_ADDRESS },
            EthAddress { address: DEFAULT_L1_RECIPIENT }
        )
    }

    fn get_l2_token_deployment_calldata(
        initial_owner: ContractAddress,
        permitted_minter: ContractAddress,
        token_gov: ContractAddress,
        initial_supply: u256,
    ) -> Span<felt252> {
        // Set the constructor calldata.
        let mut calldata = ArrayTrait::new();
        'NAME'.serialize(ref calldata);
        'SYMBOL'.serialize(ref calldata);
        18_u8.serialize(ref calldata);
        initial_supply.serialize(ref calldata);
        initial_owner.serialize(ref calldata);
        permitted_minter.serialize(ref calldata);
        token_gov.serialize(ref calldata);
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
        calldata.span()
    }

    fn get_votes_lock_deployment_calldata(
        locked_token: ContractAddress, token_gov: ContractAddress,
    ) -> Span<felt252> {
        // Set the constructor calldata.
        let mut calldata = ArrayTrait::new();
        'NAME'.serialize(ref calldata);
        'SYMBOL'.serialize(ref calldata);
        18_u8.serialize(ref calldata);
        locked_token.serialize(ref calldata);
        token_gov.serialize(ref calldata);
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);
        calldata.span()
    }

    fn simple_deploy_token() -> ContractAddress {
        let permitted_minter = starknet::contract_address_const::<9256>();
        let initial_owner = initial_owner();
        deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000_u256)
    }

    fn simple_deploy_lockable_token() -> ContractAddress {
        let initial_owner = initial_owner();
        deploy_lockable_token(:initial_owner, initial_supply: 1000_u256)
    }

    fn deploy_l2_token(
        initial_owner: ContractAddress, permitted_minter: ContractAddress, initial_supply: u256,
    ) -> ContractAddress {
        let calldata = get_l2_token_deployment_calldata(
            :initial_owner, :permitted_minter, token_gov: caller(), :initial_supply
        );

        // Set the caller address for all the functions calls (except the constructor).
        set_contract_address_as_caller();

        // Deploy the contract.
        let (l2_token, _) = deploy_syscall(
            ERC20::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false
        )
            .unwrap();
        l2_token
    }

    fn deploy_lockable_token(
        initial_owner: ContractAddress, initial_supply: u256,
    ) -> ContractAddress {
        let calldata = get_l2_token_deployment_calldata(
            :initial_owner,
            permitted_minter: permitted_minter(),
            token_gov: caller(),
            :initial_supply
        );

        // Set the caller address for all the functions calls (except the constructor).
        set_contract_address_as_caller();

        // Deploy the contract.
        let (token, _) = deploy_syscall(lockable_erc20_class_hash(), 0, calldata, false).unwrap();
        token
    }

    fn deploy_votes_lock(locked_token: ContractAddress) -> ContractAddress {
        let calldata = get_votes_lock_deployment_calldata(:locked_token, token_gov: locked_token);

        // Set the caller address for all the functions calls (except the constructor).
        set_contract_address_as_caller();

        // Deploy the contract.
        let (erc20_votes_lock, _) = deploy_syscall(
            erc20_votes_lock_class_hash(), 0, calldata, false
        )
            .unwrap();
        erc20_votes_lock
    }


    fn deploy_lock_and_votes_tokens(initial_supply: u256) -> (ContractAddress, ContractAddress) {
        let lockable_token = deploy_lockable_token(initial_owner: caller(), :initial_supply);
        let votes_lock_token = deploy_votes_lock(locked_token: lockable_token);
        (lockable_token, votes_lock_token)
    }

    fn deploy_lock_and_votes_tokens_with_owner(
        initial_owner: ContractAddress, initial_supply: u256
    ) -> (ContractAddress, ContractAddress) {
        let lockable_token = deploy_lockable_token(:initial_owner, :initial_supply);
        let votes_lock_token = deploy_votes_lock(locked_token: lockable_token);
        (lockable_token, votes_lock_token)
    }


    fn deploy_upgraded_legacy_bridge(
        l1_token: EthAddress, l2_recipient: ContractAddress, token_mismatch: bool
    ) -> ContractAddress {
        // Deploy the contract.
        let mut calldata = array![];
        let (token_test_setup_address, _) = deploy_syscall(
            TokenTestSetup::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false
        )
            .unwrap();
        let token_test_setup = ITokenTestSetupDispatcher {
            contract_address: token_test_setup_address
        };

        if token_mismatch {
            token_test_setup
                .set_l2_token_and_replace(
                    :l1_token,
                    l2_token: starknet::contract_address_const::<13>(),
                    l2_token_for_mapping: starknet::contract_address_const::<14>()
                );
            return token_test_setup_address;
        }

        // If token_mismatch is false, deploy an l2 token, set the relevant storage variables and
        // then replace to the token bridge contract.
        let l2_token = deploy_l2_token(
            initial_owner: l2_recipient,
            permitted_minter: token_test_setup_address,
            initial_supply: 1000
        );

        token_test_setup
            .set_l2_token_and_replace(:l1_token, :l2_token, l2_token_for_mapping: l2_token);

        // Since a a test contract was replaced to the brigde, the bridge constructor was not
        // called; hence _initialize_roles was not called.
        // Set the caller address for the _initialize_roles - GOVERNANCE_ADMIN role will be granted
        // to the caller.
        starknet::testing::set_caller_address(address: caller());
        // Set the token_test_setup_address (token_bridge_address) to be the contract address since
        //  an internal funciton is being called later.
        starknet::testing::set_contract_address(address: token_test_setup_address);
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::RolesInternal::_initialize_roles(ref token_bridge_state);

        token_test_setup_address
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


    fn get_mintable_token(l2_token: ContractAddress) -> IMintableTokenDispatcher {
        IMintableTokenDispatcher { contract_address: l2_token }
    }

    // Returns the last event in the queue. After this call, the evnet queue is empty.
    fn pop_and_deserialize_last_event<T, impl TEvent: starknet::Event<T>, impl TDrop: Drop<T>>(
        address: ContractAddress
    ) -> T {
        let mut prev_log = starknet::testing::pop_log_raw(address: address)
            .expect('Event queue is empty.');
        loop {
            match starknet::testing::pop_log_raw(:address) {
                Option::Some(log) => { prev_log = log; },
                Option::None(()) => { break; },
            };
        };
        deserialize_event(raw_event: prev_log)
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
                Option::Some(_) => { events.append(log.unwrap()); },
                Option::None(()) => { break; },
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

    fn set_caller_as_upgrade_governor(replaceable_address: ContractAddress) {
        let contract_roles = get_roles(contract_address: replaceable_address);
        contract_roles.register_upgrade_governor(account: caller());
    }

    fn set_caller_as_app_role_admin_app_governor(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_app_governor(account: caller());
    }

    fn set_caller_as_security_admin(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_admin(account: caller());
    }

    fn set_caller_as_security_agent(token_bridge_address: ContractAddress) {
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_agent(account: caller());
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

    fn withdraw_and_validate(
        token_bridge_address: ContractAddress,
        withdraw_from: ContractAddress,
        l1_recipient: EthAddress,
        l1_token: EthAddress,
        amount_to_withdraw: u256,
    ) {
        let token_bridge = get_token_bridge(:token_bridge_address);

        let l2_token = token_bridge.get_l2_token(:l1_token);
        let erc20_token = get_erc20_token(:l2_token);
        let total_supply = erc20_token.total_supply();
        let balance_before = erc20_token.balance_of(withdraw_from);

        starknet::testing::set_contract_address(address: withdraw_from);
        token_bridge.initiate_token_withdraw(:l1_token, :l1_recipient, amount: amount_to_withdraw);
        // Validate the new balance and total supply.
        assert(
            erc20_token.balance_of(withdraw_from) == balance_before - amount_to_withdraw,
            'INCONSISTENT_WITHDRAW_BALANCE'
        );
        assert(
            erc20_token.total_supply() == total_supply - amount_to_withdraw,
            'INIT_WITHDRAW_SUPPLY_ERROR'
        );
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        assert(
            emitted_event == Event::WithdrawInitiated(
                WithdrawInitiated {
                    l1_token: l1_token,
                    l1_recipient: l1_recipient,
                    amount: amount_to_withdraw,
                    caller_address: withdraw_from
                }
            ),
            'WithdrawInitiated Error'
        );
    }

    fn enable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token = token_bridge.get_l2_token(:l1_token);
        set_contract_address_as_caller();
        set_caller_as_security_agent(:token_bridge_address);
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        token_bridge_admin.enable_withdrawal_limit(:l1_token);
        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        let sender = caller();
        assert(
            emitted_event == Event::WithdrawalLimitEnabled(
                WithdrawalLimitEnabled { sender, l1_token }
            ),
            'WithdrawalLimitEnabled Error'
        );
    }

    fn disable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token = token_bridge.get_l2_token(:l1_token);
        set_contract_address_as_caller();
        set_caller_as_security_admin(:token_bridge_address);
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        token_bridge_admin.disable_withdrawal_limit(:l1_token);

        let emitted_event = pop_and_deserialize_last_event(address: token_bridge_address);
        let sender = caller();
        assert(
            emitted_event == Event::WithdrawalLimitDisabled(
                WithdrawalLimitDisabled { sender, l1_token }
            ),
            'WithdrawalLimitDisabled Error'
        );
    }

    fn _get_daily_withdrawal_limit(
        token_bridge_address: ContractAddress, l1_token: EthAddress
    ) -> u256 {
        let orig = get_contract_address();
        let token_bridge = get_token_bridge(:token_bridge_address);
        let l2_token = token_bridge.get_l2_token(:l1_token);
        starknet::testing::set_contract_address(address: token_bridge_address);
        let token_bridge_state = TokenBridge::contract_state_for_testing();
        let daily_withdrawal_limit =
            TokenBridge::WithdrawalLimitInternal::get_daily_withdrawal_limit(
            @token_bridge_state, :l2_token
        );
        starknet::testing::set_contract_address(address: orig);
        daily_withdrawal_limit
    }

    fn prepare_bridge_for_deploy_token(
        token_bridge_address: ContractAddress, l1_bridge_address: EthAddress
    ) {
        let orig = get_contract_address();
        let token_bridge = get_token_bridge(:token_bridge_address);

        set_contract_address_as_caller();
        // Get the token bridge admin interface and set the caller as the app governer (and as App
        // Role Admin).
        let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
        set_caller_as_app_role_admin_app_governor(:token_bridge_address);

        token_bridge_admin.set_l1_bridge(:l1_bridge_address);

        // Set ERC20 class hash.
        token_bridge_admin.set_erc20_class_hash(stock_erc20_class_hash());

        // Set l2 token gov on the bridge.
        token_bridge_admin.set_l2_token_governance(caller());

        starknet::testing::set_contract_address(address: orig);
    }

    // Prepares the bridge for deploying a new token and then deploys it.
    fn deploy_new_token(
        token_bridge_address: ContractAddress, l1_bridge_address: EthAddress, l1_token: EthAddress
    ) {
        prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);
        // Set the contract address to be of the token bridge, so we can simulate l1 message handler
        // invocations on the token bridge contract instance deployed at that address.
        starknet::testing::set_contract_address(token_bridge_address);

        // Deploy token contract.
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_deployment(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l1_token,
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
        l1_token: EthAddress,
        depositor: EthAddress,
        l2_recipient: ContractAddress,
        amount_to_deposit: u256
    ) {
        deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        TokenBridge::handle_token_deposit(
            ref token_bridge_state,
            from_address: l1_bridge_address.into(),
            :l1_token,
            :depositor,
            :l2_recipient,
            amount: amount_to_deposit
        );
    }

    fn deploy_account_internal(
        account_contract_class_hash: ClassHash, public_key: felt252
    ) -> ContractAddress {
        // Deploy the contract.
        let calldata = array![public_key];
        let (account_address, _) = deploy_syscall(
            account_contract_class_hash, 0, calldata.span(), false
        )
            .unwrap();
        account_address
    }

    fn deploy_account(public_key: felt252) -> ContractAddress {
        deploy_account_internal(
            account_contract_class_hash: TestAccount::TEST_CLASS_HASH.try_into().unwrap(),
            :public_key
        )
    }
}
