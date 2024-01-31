//! SPDX-License-Identifier: MIT
//! OpenZeppelin Contracts for Cairo v0.7.0 (token/erc20/erc20.cairo)
//!
//! # ERC20 Contract and Implementation
//!
//! This ERC20 contract includes both a library and a basic preset implementation.
//! The library is agnostic regarding how tokens are created; however,
//! the preset implementation sets the initial supply in the constructor.
//! A derived contract can use [_mint](_mint) to create a different supply mechanism.

#[starknet::contract]
mod ERC20Lockable {
    use src::err_msg::AccessErrors as AccessErrors;
    use src::err_msg::ERC20Errors as ERC20Errors;
    use src::err_msg::ReplaceErrors as ReplaceErrors;

    use integer::BoundedInt;
    use openzeppelin::token::erc20::interface::IERC20;
    use openzeppelin::token::erc20::interface::IERC20CamelOnly;
    use src::strk::eip712helper::{
        calc_domain_hash, lock_and_delegate_message_hash, validate_signature
    };
    use src::mintable_token_interface::{IMintableToken, IMintableTokenCamel};
    use src::mintable_lock_interface::{
        ILockAndDelegate, IMintableLock, IMintableLockDispatcher, IMintableLockDispatcherTrait,
        ILockingContract
    };
    use src::access_control_interface::{
        IAccessControl, RoleId, RoleAdminChanged, RoleGranted, RoleRevoked
    };
    use src::roles_interface::IMinimalRoles;
    use src::roles_interface::{
        GOVERNANCE_ADMIN, UPGRADE_GOVERNOR, GovernanceAdminAdded, GovernanceAdminRemoved,
        UpgradeGovernorAdded, UpgradeGovernorRemoved
    };

    use src::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait,
        EIC_INITIALIZE_SELECTOR, IMPLEMENTATION_EXPIRATION, ImplementationAdded,
        ImplementationRemoved, ImplementationReplaced, ImplementationFinalized
    };
    use starknet::ContractAddress;
    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};
    use starknet::{get_caller_address, get_block_timestamp};
    use starknet::syscalls::library_call_syscall;

    #[storage]
    struct Storage {
        ERC20_name: felt252,
        ERC20_symbol: felt252,
        ERC20_decimals: u8,
        ERC20_total_supply: u256,
        ERC20_balances: LegacyMap<ContractAddress, u256>,
        ERC20_allowances: LegacyMap<(ContractAddress, ContractAddress), u256>,
        // --- Lock And Delegate ---
        // Address of the contract that is used to lock & delegate on.
        locking_contract: ContractAddress,
        // Hashes of Lock & Delegate called by signature, to prevent replay.
        recorded_locks: LegacyMap<felt252, bool>,
        // EIP 712 domain separation.
        domain_hash: felt252,
        // --- Mintable Token ---
        permitted_minter: ContractAddress,
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
        Transfer: Transfer,
        Approval: Approval,
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
    }

    /// Emitted when tokens are moved from address `from` to address `to`.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct Transfer {
        // #[key] - Not indexed, to maintain backward compatibility.
        from: ContractAddress,
        // #[key] - Not indexed, to maintain backward compatibility.
        to: ContractAddress,
        value: u256
    }

    /// Emitted when the allowance of a `spender` for an `owner` is set by a call
    /// to [approve](approve). `value` is the new allowance.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct Approval {
        // #[key] - Not indexed, to maintain backward compatibility.
        owner: ContractAddress,
        // #[key] - Not indexed, to maintain backward compatibility.
        spender: ContractAddress,
        value: u256
    }

    /// Initializes the state of the ERC20 contract. This includes setting the
    /// initial supply of tokens as well as the recipient of the initial supply.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        initial_supply: u256,
        recipient: ContractAddress,
        permitted_minter: ContractAddress,
        provisional_governance_admin: ContractAddress,
        upgrade_delay: u64,
    ) {
        self.initializer(name, symbol, decimals);
        self._mint(recipient, initial_supply);
        assert(permitted_minter.is_non_zero(), AccessErrors::INVALID_MINTER);
        self.permitted_minter.write(permitted_minter);
        self._initialize_roles(:provisional_governance_admin);
        self.upgrade_delay.write(upgrade_delay);
        self.domain_hash.write(calc_domain_hash());
    }


    #[generate_trait]
    impl RolesInternal of _RolesInternal {
        // --- Roles ---
        fn _grant_role_and_emit(
            ref self: ContractState, role: RoleId, account: ContractAddress, event: Event
        ) {
            if !self.has_role(:role, :account) {
                assert(account.is_non_zero(), AccessErrors::ZERO_ADDRESS);
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
            assert(un_initialized, AccessErrors::ALREADY_INITIALIZED);
            assert(
                provisional_governance_admin.is_non_zero(), AccessErrors::ZERO_ADDRESS_GOV_ADMIN
            );
            self._grant_role(role: GOVERNANCE_ADMIN, account: provisional_governance_admin);
            self._set_role_admin(role: GOVERNANCE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: UPGRADE_GOVERNOR, admin_role: GOVERNANCE_ADMIN);
        }

        fn only_upgrade_governor(self: @ContractState) {
            assert(
                self.is_upgrade_governor(get_caller_address()), AccessErrors::ONLY_UPGRADE_GOVERNOR
            );
        }
    }

    //
    // External
    //

    // Sets the address of the locking contract.
    #[external(v0)]
    impl LockingContract of ILockingContract<ContractState> {
        fn set_locking_contract(ref self: ContractState, locking_contract: ContractAddress) {
            self.only_upgrade_governor();
            assert(self.locking_contract.read().is_zero(), 'LOCKING_CONTRACT_ALREADY_SET');
            assert(locking_contract.is_non_zero(), 'ZERO_ADDRESS');
            self.locking_contract.write(locking_contract);
        }

        fn get_locking_contract(self: @ContractState) -> ContractAddress {
            self.locking_contract.read()
        }
    }

    #[external(v0)]
    impl LockAndDelegate of ILockAndDelegate<ContractState> {
        fn lock_and_delegate(ref self: ContractState, delegatee: ContractAddress, amount: u256) {
            let account = get_caller_address();
            self._lock_and_delegate(:account, :delegatee, :amount);
        }

        fn lock_and_delegate_by_sig(
            ref self: ContractState,
            account: ContractAddress,
            delegatee: ContractAddress,
            amount: u256,
            nonce: felt252,
            expiry: u64,
            signature: Array<felt252>
        ) {
            assert(starknet::get_block_timestamp() <= expiry, 'SIGNATURE_EXPIRED');
            let domain = self.domain_hash.read();
            let hash = lock_and_delegate_message_hash(
                :domain, :account, :delegatee, :amount, :nonce, :expiry
            );

            // Assert this signed request was not used.
            let is_known_hash = self.recorded_locks.read(hash);
            assert(is_known_hash == false, 'SIGNED_REQUEST_ALREADY_USED');

            // Mark the request as used to prevent future replay.
            self.recorded_locks.write(hash, true);

            validate_signature(:account, :hash, :signature);
            self._lock_and_delegate(:account, :delegatee, :amount);
        }
    }

    #[generate_trait]
    impl LockInternal of _LockInternal {
        fn _lock_and_delegate(
            ref self: ContractState,
            account: ContractAddress,
            delegatee: ContractAddress,
            amount: u256
        ) {
            let locking_contract = self.locking_contract.read();
            assert(locking_contract.is_non_zero(), 'LOCKING_CONTRACT_NOT_SET');
            self._increase_account_allowance(:account, spender: locking_contract, :amount);
            IMintableLockDispatcher { contract_address: locking_contract }
                .permissioned_lock_and_delegate(:account, :delegatee, :amount);
        }

        fn _increase_account_allowance(
            ref self: ContractState,
            account: ContractAddress,
            spender: ContractAddress,
            amount: u256
        ) {
            let current_allowance = self.ERC20_allowances.read((account, spender));
            // Skip, in case of allowance + amount exceed max_uint.
            if current_allowance <= BoundedInt::max() - amount {
                self._approve(owner: account, :spender, amount: (current_allowance + amount));
            }
        }
    }

    #[external(v0)]
    impl MintableToken of IMintableToken<ContractState> {
        fn permissioned_mint(ref self: ContractState, account: ContractAddress, amount: u256) {
            assert(get_caller_address() == self.permitted_minter.read(), AccessErrors::ONLY_MINTER);
            self._mint(account, :amount);
        }
        fn permissioned_burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            assert(get_caller_address() == self.permitted_minter.read(), AccessErrors::ONLY_MINTER);
            self._burn(account, :amount);
        }
    }

    #[external(v0)]
    impl MintableTokenCamelImpl of IMintableTokenCamel<ContractState> {
        fn permissionedMint(ref self: ContractState, account: ContractAddress, amount: u256) {
            MintableToken::permissioned_mint(ref self, account, amount);
        }
        fn permissionedBurn(ref self: ContractState, account: ContractAddress, amount: u256) {
            MintableToken::permissioned_burn(ref self, account, amount);
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
        // Returns if finalized.
        fn is_finalized(self: @ContractState) -> bool {
            self.finalized.read()
        }

        // Sets the implementation as finalized.
        fn finalize(ref self: ContractState) {
            self.finalized.write(true);
        }


        // Sets the implementation activation time.
        fn set_impl_activation_time(
            ref self: ContractState, implementation_data: ImplementationData, activation_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.write(impl_key, activation_time);
        }

        // Returns the implementation activation time.
        fn get_impl_expiration_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.read(impl_key)
        }

        // Sets the implementation expiration time.
        fn set_impl_expiration_time(
            ref self: ContractState, implementation_data: ImplementationData, expiration_time: u64
        ) {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_expiration_time.write(impl_key, expiration_time);
        }
    }

    #[external(v0)]
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
            assert(!self.is_finalized(), ReplaceErrors::FINALIZED);

            let now = get_block_timestamp();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);
            let impl_expiration_time = self.get_impl_expiration_time(:implementation_data);

            // Zero activation time means that this implementation & init vector combination
            // was not previously added.
            assert(impl_activation_time.is_non_zero(), ReplaceErrors::UNKNOWN_IMPLEMENTATION);

            assert(impl_activation_time <= now, ReplaceErrors::NOT_ENABLED_YET);
            assert(now <= impl_expiration_time, ReplaceErrors::IMPLEMENTATION_EXPIRED);

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
                    assert(res.is_ok(), ReplaceErrors::EIC_LIB_CALL_FAILED);
                },
                Option::None(()) => {}
            };

            // Replace the class hash.
            let result = starknet::replace_class_syscall(implementation_data.impl_hash);
            assert(result.is_ok(), ReplaceErrors::REPLACE_CLASS_HASH_FAILED);

            // Remove implementation, as it was consumed.
            self.set_impl_activation_time(:implementation_data, activation_time: 0);
            self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
        }
    }

    #[external(v0)]
    impl AccessControlImplExternal of IAccessControl<ContractState> {
        fn has_role(self: @ContractState, role: RoleId, account: ContractAddress) -> bool {
            self.role_members.read((role, account))
        }

        fn get_role_admin(self: @ContractState, role: RoleId) -> RoleId {
            self.role_admin.read(role)
        }
    }

    #[generate_trait]
    impl AccessControlImplInternal of IAccessControlInternal {
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
            assert(get_caller_address() == account, AccessErrors::ONLY_SELF_CAN_RENOUNCE);
            self._revoke_role(:role, :account);
        }
    }

    #[generate_trait]
    impl InternalAccessControl of _InternalAccessControl {
        fn assert_only_role(self: @ContractState, role: RoleId) {
            let authorized: bool = self.has_role(:role, account: get_caller_address());
            assert(authorized, AccessErrors::CALLER_MISSING_ROLE);
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

    #[external(v0)]
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
            assert(role != GOVERNANCE_ADMIN, AccessErrors::GOV_ADMIN_CANNOT_RENOUNCE);
            self.renounce_role(:role, account: get_caller_address())
        }
    }


    //
    // External
    //

    #[external(v0)]
    impl ERC20Impl of IERC20<ContractState> {
        /// Returns the name of the token.
        fn name(self: @ContractState) -> felt252 {
            self.ERC20_name.read()
        }

        /// Returns the ticker symbol of the token, usually a shorter version of the name.
        fn symbol(self: @ContractState) -> felt252 {
            self.ERC20_symbol.read()
        }

        /// Returns the number of decimals used to get its user representation.
        fn decimals(self: @ContractState) -> u8 {
            self.ERC20_decimals.read()
        }

        /// Returns the value of tokens in existence.
        fn total_supply(self: @ContractState) -> u256 {
            self.ERC20_total_supply.read()
        }

        /// Returns the amount of tokens owned by `account`.
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.ERC20_balances.read(account)
        }

        /// Returns the remaining number of tokens that `spender` is
        /// allowed to spend on behalf of `owner` through [transfer_from](transfer_from).
        /// This is zero by default.
        /// This value changes when [approve](approve) or [transfer_from](transfer_from)
        /// are called.
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.ERC20_allowances.read((owner, spender))
        }

        /// Moves `amount` tokens from the caller's token balance to `to`.
        /// Emits a [Transfer](Transfer) event.
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            self._transfer(sender, recipient, amount);
            true
        }

        /// Moves `amount` tokens from `from` to `to` using the allowance mechanism.
        /// `amount` is then deducted from the caller's allowance.
        /// Emits a [Transfer](Transfer) event.
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let caller = get_caller_address();
            self._spend_allowance(sender, caller, amount);
            self._transfer(sender, recipient, amount);
            true
        }

        /// Sets `amount` as the allowance of `spender` over the caller’s tokens.
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self._approve(caller, spender, amount);
            true
        }
    }

    /// Increases the allowance granted from the caller to `spender` by `added_value`.
    /// Emits an [Approval](Approval) event indicating the updated allowance.
    #[external(v0)]
    fn increase_allowance(
        ref self: ContractState, spender: ContractAddress, added_value: u256
    ) -> bool {
        self._increase_allowance(spender, added_value)
    }

    /// Decreases the allowance granted from the caller to `spender` by `subtracted_value`.
    /// Emits an [Approval](Approval) event indicating the updated allowance.
    #[external(v0)]
    fn decrease_allowance(
        ref self: ContractState, spender: ContractAddress, subtracted_value: u256
    ) -> bool {
        self._decrease_allowance(spender, subtracted_value)
    }

    #[external(v0)]
    impl ERC20CamelOnlyImpl of IERC20CamelOnly<ContractState> {
        /// Camel case support.
        /// See [total_supply](total-supply).
        fn totalSupply(self: @ContractState) -> u256 {
            ERC20Impl::total_supply(self)
        }

        /// Camel case support.
        /// See [balance_of](balance_of).
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            ERC20Impl::balance_of(self, account)
        }

        /// Camel case support.
        /// See [transfer_from](transfer_from).
        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            ERC20Impl::transfer_from(ref self, sender, recipient, amount)
        }
    }

    /// Camel case support.
    /// See [increase_allowance](increase_allowance).
    #[external(v0)]
    fn increaseAllowance(
        ref self: ContractState, spender: ContractAddress, addedValue: u256
    ) -> bool {
        increase_allowance(ref self, spender, addedValue)
    }

    /// Camel case support.
    /// See [decrease_allowance](decrease_allowance).
    #[external(v0)]
    fn decreaseAllowance(
        ref self: ContractState, spender: ContractAddress, subtractedValue: u256
    ) -> bool {
        decrease_allowance(ref self, spender, subtractedValue)
    }

    //
    // Internal
    //

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Initializes the contract by setting the token name and symbol.
        /// To prevent reinitialization, this should only be used inside of a contract constructor.
        fn initializer(ref self: ContractState, name: felt252, symbol: felt252, decimals: u8) {
            self.ERC20_name.write(name);
            self.ERC20_symbol.write(symbol);
            self.ERC20_decimals.write(decimals);
        }

        /// Internal method that moves an `amount` of tokens from `from` to `to`.
        /// Emits a [Transfer](Transfer) event.
        fn _transfer(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            assert(!sender.is_zero(), ERC20Errors::TRANSFER_FROM_ZERO);
            assert(!recipient.is_zero(), ERC20Errors::TRANSFER_TO_ZERO);
            self.ERC20_balances.write(sender, self.ERC20_balances.read(sender) - amount);
            self.ERC20_balances.write(recipient, self.ERC20_balances.read(recipient) + amount);
            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        /// Internal method that sets `amount` as the allowance of `spender` over the
        /// `owner`s tokens.
        /// Emits an [Approval](Approval) event.
        fn _approve(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            assert(!owner.is_zero(), ERC20Errors::APPROVE_FROM_ZERO);
            assert(!spender.is_zero(), ERC20Errors::APPROVE_TO_ZERO);
            self.ERC20_allowances.write((owner, spender), amount);
            self.emit(Approval { owner, spender, value: amount });
        }

        /// Creates a `value` amount of tokens and assigns them to `account`.
        /// Emits a [Transfer](Transfer) event with `from` set to the zero address.
        fn _mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            assert(!recipient.is_zero(), ERC20Errors::MINT_TO_ZERO);
            self.ERC20_total_supply.write(self.ERC20_total_supply.read() + amount);
            self.ERC20_balances.write(recipient, self.ERC20_balances.read(recipient) + amount);
            self.emit(Transfer { from: Zeroable::zero(), to: recipient, value: amount });
        }

        /// Destroys a `value` amount of tokens from `account`.
        /// Emits a [Transfer](Transfer) event with `to` set to the zero address.
        fn _burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            assert(!account.is_zero(), ERC20Errors::BURN_FROM_ZERO);
            self.ERC20_total_supply.write(self.ERC20_total_supply.read() - amount);
            self.ERC20_balances.write(account, self.ERC20_balances.read(account) - amount);
            self.emit(Transfer { from: account, to: Zeroable::zero(), value: amount });
        }

        /// Internal method for the external [increase_allowance](increase_allowance).
        /// Emits an [Approval](Approval) event indicating the updated allowance.
        fn _increase_allowance(
            ref self: ContractState, spender: ContractAddress, added_value: u256
        ) -> bool {
            let caller = get_caller_address();
            self
                ._approve(
                    caller, spender, self.ERC20_allowances.read((caller, spender)) + added_value
                );
            true
        }

        /// Internal method for the external [decrease_allowance](decrease_allowance).
        /// Emits an [Approval](Approval) event indicating the updated allowance.
        fn _decrease_allowance(
            ref self: ContractState, spender: ContractAddress, subtracted_value: u256
        ) -> bool {
            let caller = get_caller_address();
            self
                ._approve(
                    caller,
                    spender,
                    self.ERC20_allowances.read((caller, spender)) - subtracted_value
                );
            true
        }

        /// Updates `owner`s allowance for `spender` based on spent `amount`.
        /// Does not update the allowance value in case of infinite allowance.
        /// Possibly emits an [Approval](Approval) event.
        fn _spend_allowance(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            let current_allowance = self.ERC20_allowances.read((owner, spender));
            if current_allowance != BoundedInt::max() {
                self._approve(owner, spender, current_allowance - amount);
            }
        }
    }
}
