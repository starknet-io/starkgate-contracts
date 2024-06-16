// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts for Cairo v0.8.0-beta.1 (token/erc20/presets/erc20votes.cairo)

/// ERC20 with the ERC20Votes extension.
#[starknet::contract]
mod ERC20VotesLock {
    use core::result::ResultTrait;
    use src::access_control_interface::{
        IAccessControl, RoleId, RoleAdminChanged, RoleGranted, RoleRevoked
    };
    use src::roles_interface::IMinimalRoles;
    use src::roles_interface::{
        GOVERNANCE_ADMIN, UPGRADE_GOVERNOR, GovernanceAdminAdded, GovernanceAdminRemoved,
        UpgradeGovernorAdded, UpgradeGovernorRemoved
    };
    use src::err_msg::AccessErrors::{
        INVALID_TOKEN, CALLER_MISSING_ROLE, ZERO_ADDRESS, ALREADY_INITIALIZED,
        ONLY_UPGRADE_GOVERNOR, ONLY_SELF_CAN_RENOUNCE, GOV_ADMIN_CANNOT_RENOUNCE,
        ZERO_ADDRESS_GOV_ADMIN,
    };
    use src::err_msg::ReplaceErrors::{
        FINALIZED, UNKNOWN_IMPLEMENTATION, NOT_ENABLED_YET, IMPLEMENTATION_EXPIRED,
        EIC_LIB_CALL_FAILED, REPLACE_CLASS_HASH_FAILED,
    };

    use src::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait,
        EIC_INITIALIZE_SELECTOR, IMPLEMENTATION_EXPIRATION, ImplementationAdded,
        ImplementationRemoved, ImplementationReplaced, ImplementationFinalized
    };

    use ERC20::InternalTrait;
    use starknet::{
        ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use starknet::syscalls::library_call_syscall;

    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use src::mintable_lock_interface::{IMintableLock, ITokenLock, Locked, Unlocked};
    use openzeppelin::governance::utils::interfaces::IVotes;
    use openzeppelin::token::erc20::ERC20;
    use openzeppelin::token::erc20::extensions::ERC20Votes;
    use openzeppelin::token::erc20::interface::{IERC20, IERC20CamelOnly};
    use openzeppelin::utils::cryptography::eip712_draft::EIP712;
    use openzeppelin::utils::nonces::Nonces;
    use openzeppelin::utils::structs::checkpoints::Checkpoint;
    const DAPP_NAME: felt252 = 'TOKEN_DELEGATION';
    const DAPP_VERSION: felt252 = '1.0.0';

    #[storage]
    struct Storage {
        locked_token: ContractAddress,
        // --- Replaceability ---
        // Delay in seconds before performing an upgrade.
        upgrade_delay: u64,
        // Timestamp by which implementation can be activated.
        impl_activation_time: LegacyMap<felt252, u64>,
        // Timestamp until which implementation can be activated.
        impl_expiration_time: LegacyMap<felt252, u64>,
        // Is the implementation finalized.
        finalized: bool,
        // --- Access Control ---
        // For each role id store its role admin id.
        role_admin: LegacyMap<RoleId, RoleId>,
        // For each role and address, stores true if the address has this role; otherwise, false.
        role_members: LegacyMap<(RoleId, ContractAddress), bool>,
    }


    #[event]
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    enum Event {
        // --- ERC20 ---
        #[flat]
        ERC20Event: ERC20::Event,
        // --- Votes ---
        #[flat]
        ERC20VotesEvent: ERC20Votes::Event,
        // --- Replaceability ---
        ImplementationAdded: ImplementationAdded,
        ImplementationRemoved: ImplementationRemoved,
        ImplementationReplaced: ImplementationReplaced,
        ImplementationFinalized: ImplementationFinalized,
        // --- Access Control ---
        RoleGranted: RoleGranted,
        RoleRevoked: RoleRevoked,
        RoleAdminChanged: RoleAdminChanged,
        // --- Roles ---
        GovernanceAdminAdded: GovernanceAdminAdded,
        GovernanceAdminRemoved: GovernanceAdminRemoved,
        UpgradeGovernorAdded: UpgradeGovernorAdded,
        UpgradeGovernorRemoved: UpgradeGovernorRemoved,
        // --- Token Lock ---
        Locked: Locked,
        Unlocked: Unlocked,
    }

    //
    // Hooks
    //

    impl ERC20VotesHooksImpl of ERC20::ERC20HooksTrait {
        fn _before_update(
            ref self: ERC20::ContractState,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {}

        fn _after_update(
            ref self: ERC20::ContractState,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            let mut unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::InternalImpl::transfer_voting_units(
                ref unsafe_state, from, recipient, amount
            );
        }
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        locked_token: ContractAddress,
        provisional_governance_admin: ContractAddress,
        upgrade_delay: u64,
    ) {
        let mut eip712_state = EIP712::unsafe_new_contract_state();
        EIP712::InternalImpl::initializer(ref eip712_state, DAPP_NAME, DAPP_VERSION);

        let mut erc20_state = ERC20::unsafe_new_contract_state();
        ERC20::InternalImpl::initializer(ref erc20_state, name, symbol, decimals);
        assert(locked_token.is_non_zero(), INVALID_TOKEN);
        self.locked_token.write(locked_token);
        self._initialize_roles(:provisional_governance_admin);
        self.upgrade_delay.write(upgrade_delay);
    }

    #[generate_trait]
    impl RolesInternal of _RolesInternal {
        // --- Roles ---
        fn _grant_role_and_emit(
            ref self: ContractState, role: RoleId, account: ContractAddress, event: Event
        ) {
            if !self.has_role(:role, :account) {
                assert(account.is_non_zero(), ZERO_ADDRESS);
                self.grant_role(:role, :account);
                self.emit(event);
            }
        }

        fn _revoke_role_and_emit(
            ref self: ContractState, role: RoleId, account: ContractAddress, event: Event
        ) {
            if self.has_role(:role, :account) {
                self.revoke_role(:role, :account);
                self.emit(event);
            }
        }

        //
        // WARNING
        // The following internal method is unprotected and should not be used outside of a
        // contract's constructor.
        //
        fn _initialize_roles(
            ref self: ContractState, provisional_governance_admin: ContractAddress
        ) {
            let un_initialized = self.get_role_admin(role: GOVERNANCE_ADMIN) == 0;
            assert(un_initialized, ALREADY_INITIALIZED);
            assert(provisional_governance_admin.is_non_zero(), ZERO_ADDRESS_GOV_ADMIN);
            self._grant_role(role: GOVERNANCE_ADMIN, account: provisional_governance_admin);
            self._set_role_admin(role: GOVERNANCE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: UPGRADE_GOVERNOR, admin_role: GOVERNANCE_ADMIN);
        }

        fn only_upgrade_governor(self: @ContractState) {
            assert(self.is_upgrade_governor(get_caller_address()), ONLY_UPGRADE_GOVERNOR);
        }
    }

    //
    // External
    //

    #[abi(embed_v0)]
    impl MintableLock of IMintableLock<ContractState> {
        fn permissioned_lock_and_delegate(
            ref self: ContractState,
            account: ContractAddress,
            delegatee: ContractAddress,
            amount: u256
        ) {
            // Only locked token.
            assert(get_caller_address() == self.locked_token.read(), 'INVALID_CALLER');

            // Lock.
            self._lock(:account, :amount);

            // Delegate.
            let mut unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::InternalImpl::_delegate(ref unsafe_state, :account, :delegatee);
        }
    }

    #[abi(embed_v0)]
    impl TokenLock of ITokenLock<ContractState> {
        fn lock(ref self: ContractState, amount: u256) {
            let account = get_caller_address();
            self._lock(:account, :amount);
        }
        fn unlock(ref self: ContractState, amount: u256) {
            let account = get_caller_address();
            self._unlock(:account, :amount);
        }
    }

    fn calc_impl_key(implementation_data: ImplementationData) -> felt252 {
        // Hash the implementation_data to obtain a key.
        let mut hash_input = ArrayTrait::new();
        implementation_data.serialize(ref hash_input);
        poseidon::poseidon_hash_span(hash_input.span())
    }

    #[generate_trait]
    impl ReplaceableInternal of _ReplaceableInternal {
        fn is_finalized(self: @ContractState) -> bool {
            self.finalized.read()
        }

        fn finalize(ref self: ContractState) {
            self.finalized.write(true);
        }

        fn set_impl_activation_time(
            ref self: ContractState, implementation_data: ImplementationData, activation_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.write(impl_key, activation_time);
        }

        fn get_impl_expiration_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.read(impl_key)
        }

        fn set_impl_expiration_time(
            ref self: ContractState, implementation_data: ImplementationData, expiration_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.write(impl_key, expiration_time);
        }
    }

    #[abi(embed_v0)]
    impl Replaceable of IReplaceable<ContractState> {
        fn get_upgrade_delay(self: @ContractState) -> u64 {
            self.upgrade_delay.read()
        }

        // Gets the implementation activation time.
        fn get_impl_activation_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.read(impl_key)
        }

        fn add_new_implementation(
            ref self: ContractState, implementation_data: ImplementationData
        ) {
            self.only_upgrade_governor();

            let activation_time = get_block_timestamp() + self.get_upgrade_delay();
            let expiration_time = activation_time + IMPLEMENTATION_EXPIRATION;
            // TODO -  add an assertion that the `implementation_data.impl_hash` is declared.
            self.set_impl_activation_time(:implementation_data, :activation_time);
            self.set_impl_expiration_time(:implementation_data, :expiration_time);
            self.emit(ImplementationAdded { implementation_data: implementation_data });
        }

        fn remove_implementation(ref self: ContractState, implementation_data: ImplementationData) {
            self.only_upgrade_governor();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);

            if (impl_activation_time.is_non_zero()) {
                self.set_impl_activation_time(:implementation_data, activation_time: 0);
                self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
                self.emit(ImplementationRemoved { implementation_data: implementation_data });
            }
        }
        // Replaces the non-finalized current implementation to one that was previously added and
        // whose activation time had passed.
        fn replace_to(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Validate implementation is not finalized.
            assert(!self.is_finalized(), FINALIZED);

            let now = get_block_timestamp();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);
            let impl_expiration_time = self.get_impl_expiration_time(:implementation_data);

            // Zero activation time means that this implementation & init vector combination
            // was not previously added.
            assert(impl_activation_time.is_non_zero(), UNKNOWN_IMPLEMENTATION);

            assert(impl_activation_time <= now, NOT_ENABLED_YET);
            assert(now <= impl_expiration_time, IMPLEMENTATION_EXPIRED);

            // We emit now so that finalize emits last (if it does).
            self.emit(ImplementationReplaced { implementation_data });

            // Finalize imeplementation, if needed.
            if (implementation_data.final) {
                self.finalize();
                self.emit(ImplementationFinalized { impl_hash: implementation_data.impl_hash });
            }

            // Handle EIC.
            match implementation_data.eic_data {
                Option::Some(eic_data) => {
                    // Wrap the calldata as a span, as preperation for the library_call_syscall
                    // invocation.
                    let mut calldata_wrapper = ArrayTrait::new();
                    eic_data.eic_init_data.serialize(ref calldata_wrapper);

                    // Invoke the EIC's initialize function as a library call.
                    let res = library_call_syscall(
                        class_hash: eic_data.eic_hash,
                        function_selector: EIC_INITIALIZE_SELECTOR,
                        calldata: calldata_wrapper.span()
                    );
                    assert(res.is_ok(), EIC_LIB_CALL_FAILED);
                },
                Option::None(()) => {}
            };

            // Replace the class hash.
            let result = starknet::replace_class_syscall(implementation_data.impl_hash);
            assert(result.is_ok(), REPLACE_CLASS_HASH_FAILED);

            // Remove implementation, as it was consumed.
            self.set_impl_activation_time(:implementation_data, activation_time: 0);
            self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
        }
    }

    #[abi(embed_v0)]
    impl AccessControlImplExternal of IAccessControl<ContractState> {
        fn has_role(self: @ContractState, role: RoleId, account: ContractAddress) -> bool {
            self.role_members.read((role, account))
        }

        fn get_role_admin(self: @ContractState, role: RoleId) -> RoleId {
            self.role_admin.read(role)
        }
    }

    #[generate_trait]
    impl LockImpl of _LockImpl {
        fn _lock(ref self: ContractState, account: ContractAddress, amount: u256) {
            let _this = get_contract_address();
            IERC20Dispatcher {
                contract_address: self.locked_token.read()
            }.transfer_from(sender: account, recipient: _this, :amount);
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            unsafe_state._mint::<ERC20VotesHooksImpl>(recipient: account, :amount);

            self.emit(Locked { account: account, amount: amount });
        }

        fn _unlock(ref self: ContractState, account: ContractAddress, amount: u256) {
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            unsafe_state._burn::<ERC20VotesHooksImpl>(:account, :amount);

            IERC20Dispatcher {
                contract_address: self.locked_token.read()
            }.transfer(recipient: account, :amount);

            self.emit(Unlocked { account: account, amount: amount });
        }
    }

    #[generate_trait]
    impl AccessControlImplInternal of _AccessControlImplInternal {
        fn grant_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            let admin = self.get_role_admin(:role);
            self.assert_only_role(role: admin);
            self._grant_role(:role, :account);
        }

        fn revoke_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            let admin = self.get_role_admin(:role);
            self.assert_only_role(role: admin);
            self._revoke_role(:role, :account);
        }

        fn renounce_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            assert(get_caller_address() == account, ONLY_SELF_CAN_RENOUNCE);
            self._revoke_role(:role, :account);
        }
    }

    #[generate_trait]
    impl InternalAccessControl of _InternalAccessControl {
        fn assert_only_role(self: @ContractState, role: RoleId) {
            let authorized: bool = self.has_role(:role, account: get_caller_address());
            assert(authorized, CALLER_MISSING_ROLE);
        }

        //
        // WARNING
        // This method is unprotected and should be used only from the contract's constructor or
        // from grant_role.
        //
        fn _grant_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            if !self.has_role(:role, :account) {
                self.role_members.write((role, account), true);
                self.emit(RoleGranted { role, account, sender: get_caller_address() });
            }
        }

        //
        // WARNING
        // This method is unprotected and should be used only from revoke_role or from
        // renounce_role.
        //
        fn _revoke_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            if self.has_role(:role, :account) {
                self.role_members.write((role, account), false);
                self.emit(RoleRevoked { role, account, sender: get_caller_address() });
            }
        }

        //
        // WARNING
        // This method is unprotected and should not be used outside of a contract's constructor.
        //

        fn _set_role_admin(ref self: ContractState, role: RoleId, admin_role: RoleId) {
            let previous_admin_role = self.get_role_admin(:role);
            self.role_admin.write(role, admin_role);
            self.emit(RoleAdminChanged { role, previous_admin_role, new_admin_role: admin_role });
        }
    }

    #[abi(embed_v0)]
    impl RolesImpl of IMinimalRoles<ContractState> {
        fn is_governance_admin(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: GOVERNANCE_ADMIN, :account)
        }

        fn is_upgrade_governor(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: UPGRADE_GOVERNOR, :account)
        }

        fn register_governance_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::GovernanceAdminAdded(
                GovernanceAdminAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: GOVERNANCE_ADMIN, :account, :event);
        }

        fn remove_governance_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::GovernanceAdminRemoved(
                GovernanceAdminRemoved {
                    removed_account: account, removed_by: get_caller_address()
                }
            );
            self._revoke_role_and_emit(role: GOVERNANCE_ADMIN, :account, :event);
        }

        fn register_upgrade_governor(ref self: ContractState, account: ContractAddress) {
            let event = Event::UpgradeGovernorAdded(
                UpgradeGovernorAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: UPGRADE_GOVERNOR, :account, :event);
        }

        fn remove_upgrade_governor(ref self: ContractState, account: ContractAddress) {
            let event = Event::UpgradeGovernorRemoved(
                UpgradeGovernorRemoved {
                    removed_account: account, removed_by: get_caller_address()
                }
            );
            self._revoke_role_and_emit(role: UPGRADE_GOVERNOR, :account, :event);
        }

        fn renounce(ref self: ContractState, role: RoleId) {
            assert(role != GOVERNANCE_ADMIN, GOV_ADMIN_CANNOT_RENOUNCE);
            self.renounce_role(:role, account: get_caller_address())
        }
    }

    #[abi(embed_v0)]
    impl ERC20Impl of IERC20<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::name(@unsafe_state)
        }

        fn symbol(self: @ContractState) -> felt252 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::symbol(@unsafe_state)
        }

        fn decimals(self: @ContractState) -> u8 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::decimals(@unsafe_state)
        }

        fn total_supply(self: @ContractState) -> u256 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::total_supply(@unsafe_state)
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::balance_of(@unsafe_state, account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            let unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::allowance(@unsafe_state, owner, spender)
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            let sender = starknet::get_caller_address();
            ERC20::InternalImpl::_transfer::<
                ERC20VotesHooksImpl
            >(ref unsafe_state, sender, recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            let caller = starknet::get_caller_address();
            ERC20::InternalImpl::_spend_allowance(ref unsafe_state, sender, caller, amount);
            ERC20::InternalImpl::_transfer::<
                ERC20VotesHooksImpl
            >(ref unsafe_state, sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::approve(ref unsafe_state, spender, amount)
        }
    }

    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl of IERC20CamelOnly<ContractState> {
        fn totalSupply(self: @ContractState) -> u256 {
            ERC20Impl::total_supply(self)
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            ERC20Impl::balance_of(self, account)
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            ERC20Impl::transfer_from(ref self, sender, recipient, amount)
        }
    }

    #[external(v0)]
    fn increase_allowance(
        ref self: ContractState, spender: ContractAddress, added_value: u256
    ) -> bool {
        let mut unsafe_state = ERC20::unsafe_new_contract_state();
        ERC20::InternalImpl::_increase_allowance(ref unsafe_state, spender, added_value)
    }

    #[external(v0)]
    fn increaseAllowance(
        ref self: ContractState, spender: ContractAddress, addedValue: u256
    ) -> bool {
        increase_allowance(ref self, spender, addedValue)
    }

    #[external(v0)]
    fn decrease_allowance(
        ref self: ContractState, spender: ContractAddress, subtracted_value: u256
    ) -> bool {
        let mut unsafe_state = ERC20::unsafe_new_contract_state();
        ERC20::InternalImpl::_decrease_allowance(ref unsafe_state, spender, subtracted_value)
    }

    #[external(v0)]
    fn decreaseAllowance(
        ref self: ContractState, spender: ContractAddress, subtractedValue: u256
    ) -> bool {
        decrease_allowance(ref self, spender, subtractedValue)
    }

    #[abi(embed_v0)]
    impl VotesImpl of IVotes<ContractState> {
        fn get_votes(self: @ContractState, account: ContractAddress) -> u256 {
            let unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::get_votes(@unsafe_state, account)
        }

        fn get_past_votes(self: @ContractState, account: ContractAddress, timepoint: u64) -> u256 {
            let unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::get_past_votes(@unsafe_state, account, timepoint)
        }

        fn get_past_total_supply(self: @ContractState, timepoint: u64) -> u256 {
            let unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::get_past_total_supply(@unsafe_state, timepoint)
        }

        fn delegates(self: @ContractState, account: ContractAddress) -> ContractAddress {
            let unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::delegates(@unsafe_state, account)
        }

        fn delegate(ref self: ContractState, delegatee: ContractAddress) {
            let mut unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::delegate(ref unsafe_state, delegatee);
        }

        fn delegate_by_sig(
            ref self: ContractState,
            delegator: ContractAddress,
            delegatee: ContractAddress,
            nonce: felt252,
            expiry: u64,
            signature: Array<felt252>
        ) {
            let mut unsafe_state = ERC20Votes::unsafe_new_contract_state();
            ERC20Votes::VotesImpl::delegate_by_sig(
                ref unsafe_state, delegator, delegatee, nonce, expiry, signature
            );
        }
    }

    /// Returns the next unused nonce for an address.
    #[external(v0)]
    fn nonces(self: @ContractState, owner: ContractAddress) -> felt252 {
        let unsafe_state = Nonces::unsafe_new_contract_state();
        Nonces::nonces(@unsafe_state, owner)
    }

    /// Get number of checkpoints for `account`.
    #[external(v0)]
    fn num_checkpoints(self: @ContractState, account: ContractAddress) -> u32 {
        let unsafe_state = ERC20Votes::unsafe_new_contract_state();
        ERC20Votes::InternalImpl::num_checkpoints(@unsafe_state, account)
    }

    /// Get the `pos`-th checkpoint for `account`.
    #[external(v0)]
    fn checkpoints(self: @ContractState, account: ContractAddress, pos: u32) -> Checkpoint {
        let unsafe_state = ERC20Votes::unsafe_new_contract_state();
        ERC20Votes::InternalImpl::checkpoints(@unsafe_state, account, pos)
    }
}
