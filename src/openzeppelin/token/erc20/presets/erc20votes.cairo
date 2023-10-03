// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts for Cairo v0.7.0 (token/erc20/presets/erc20votes.cairo)

/// ERC20 with the ERC20Votes extension.
#[starknet::contract]
mod ERC20VotesPreset {
    use core::result::ResultTrait;
    use src::access_control_interface::{IAccessControl, RoleId};
    use src::roles_interface::IMinimalRoles;
    use src::roles_interface::{GOVERNANCE_ADMIN, UPGRADE_GOVERNOR};

    use src::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait,
        EIC_INITIALIZE_SELECTOR, IMPLEMENTATION_EXPIRATION
    };

    use ERC20::InternalTrait;
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::syscalls::library_call_syscall;

    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};
    use src::mintable_token_interface::IMintableToken;
    use openzeppelin::governance::utils::interfaces::IVotes;
    use openzeppelin::token::erc20::ERC20;
    use openzeppelin::token::erc20::extensions::ERC20Votes;
    use openzeppelin::token::erc20::interface::IERC20;
    use openzeppelin::token::erc20::interface::IERC20CamelOnly;
    use openzeppelin::utils::cryptography::eip712_draft::EIP712;
    use openzeppelin::utils::structs::checkpoints::Checkpoint;

    #[storage]
    struct Storage {
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
        // --- Replaceability ---
        #[event]
        ImplementationAdded: ImplementationAdded,
        #[event]
        ImplementationRemoved: ImplementationRemoved,
        #[event]
        ImplementationReplaced: ImplementationReplaced,
        #[event]
        ImplementationFinalized: ImplementationFinalized,
        // --- Access Control ---
        #[event]
        RoleGranted: RoleGranted,
        #[event]
        RoleRevoked: RoleRevoked,
        #[event]
        RoleAdminChanged: RoleAdminChanged,
        // --- Roles ---
        #[event]
        GovernanceAdminAdded: GovernanceAdminAdded,
        #[event]
        GovernanceAdminRemoved: GovernanceAdminRemoved,
        #[event]
        UpgradeGovernorAdded: UpgradeGovernorAdded,
        #[event]
        UpgradeGovernorRemoved: UpgradeGovernorRemoved,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct ImplementationAdded {
        implementation_data: ImplementationData,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct ImplementationRemoved {
        implementation_data: ImplementationData,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct ImplementationReplaced {
        implementation_data: ImplementationData,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct ImplementationFinalized {
        impl_hash: ClassHash,
    }

    // An event that is emitted when `account` is granted `role`.
    // `sender` is the account that originated the contract call, an admin role
    // bearer (except if `_grant_role` is called during initialization from the constructor).
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct RoleGranted {
        role: RoleId,
        account: ContractAddress,
        sender: ContractAddress,
    }

    // An event that is emitted when `account` is revoked `role`.
    // `sender` is the account that originated the contract call:
    //   - If using `revoke_role`, it is the admin role bearer.
    //   - If using `renounce_role`, it is the role bearer (i.e. `account`).
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct RoleRevoked {
        role: RoleId,
        account: ContractAddress,
        sender: ContractAddress,
    }

    // An event that is emitted when `new_admin_role` is set as `role`'s admin role, replacing
    // `previous_admin_role`.
    // `0` is the starting admin for all roles, despite {RoleAdminChanged} not
    // being emitted signaling this.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct RoleAdminChanged {
        role: RoleId,
        previous_admin_role: RoleId,
        new_admin_role: RoleId,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct GovernanceAdminAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct GovernanceAdminRemoved {
        removed_account: ContractAddress,
        removed_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct UpgradeGovernorAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct UpgradeGovernorRemoved {
        removed_account: ContractAddress,
        removed_by: ContractAddress,
    }


    //
    // Hooks
    //

    impl ERC20VotesHooksImpl of ERC20::ERC20HooksTrait {
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
        initial_supply: u256,
        recipient: ContractAddress,
        permitted_minter: ContractAddress,
        dapp_name: felt252,
        dapp_version: felt252,
        upgrade_delay: u64,
    ) {
        let mut eip712_state = EIP712::unsafe_new_contract_state();
        EIP712::InternalImpl::initializer(ref eip712_state, dapp_name, dapp_version);

        let mut erc20_state = ERC20::unsafe_new_contract_state();
        ERC20::InternalImpl::initializer(ref erc20_state, name, symbol, decimals);
        ERC20::InternalImpl::_mint::<ERC20VotesHooksImpl>(
            ref erc20_state, recipient, initial_supply
        );
        assert(permitted_minter.is_non_zero(), 'INVALID_MINTER_ADDRESS');
        self.permitted_minter.write(permitted_minter);
        self._initialize_roles(provisional_governance_admin: get_caller_address());
        self.upgrade_delay.write(upgrade_delay);
    }

    #[generate_trait]
    impl InternalFunctions of IInternalFunctions {
        // --- Replaceability ---
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

        // --- Access Control ---
        fn assert_only_role(self: @ContractState, role: RoleId) {
            let authorized: bool = self.has_role(:role, account: get_caller_address());
            assert(authorized, 'Caller is missing role');
        }

        //
        // WARNING
        // This method is unprotected and should be used only from the contract's constructor or
        // from grant_role.
        //

        fn _grant_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            if !self.has_role(:role, :account) {
                self.role_members.write((role, account), true);
                self
                    .emit(
                        Event::RoleGranted(
                            RoleGranted { role, account, sender: get_caller_address() }
                        )
                    );
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
                self
                    .emit(
                        Event::RoleRevoked(
                            RoleRevoked { role, account, sender: get_caller_address() }
                        )
                    );
            }
        }

        //
        // WARNING
        // This method is unprotected and should not be used outside of a contract's constructor.
        //

        fn _set_role_admin(ref self: ContractState, role: RoleId, admin_role: RoleId) {
            let previous_admin_role = self.get_role_admin(:role);
            self.role_admin.write(role, admin_role);
            self
                .emit(
                    Event::RoleAdminChanged(
                        RoleAdminChanged { role, previous_admin_role, new_admin_role: admin_role }
                    )
                );
        }

        // --- Roles ---
        fn _grant_role_and_emit(
            ref self: ContractState, role: RoleId, account: ContractAddress, event: Event
        ) {
            if !self.has_role(:role, :account) {
                assert(account.is_non_zero(), 'INVALID_ACCOUNT_ADDRESS');
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
            assert(un_initialized, 'ROLES_ALREADY_INITIALIZED');
            assert(provisional_governance_admin.is_non_zero(), 'ZERO_PROVISIONAL_GOV_ADMIN');
            self._grant_role(role: GOVERNANCE_ADMIN, account: provisional_governance_admin);
            self._set_role_admin(role: GOVERNANCE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: UPGRADE_GOVERNOR, admin_role: GOVERNANCE_ADMIN);
        }

        fn only_governance_admin(self: @ContractState) {
            assert(self.is_governance_admin(get_caller_address()), 'ONLY_GOVERNANCE_ADMIN');
        }
        fn only_upgrade_governor(self: @ContractState) {
            assert(self.is_upgrade_governor(get_caller_address()), 'ONLY_UPGRADE_GOVERNOR');
        }
    }

    //
    // External
    //

    #[external(v0)]
    impl MintableToken of IMintableToken<ContractState> {
        fn permissioned_mint(ref self: ContractState, account: ContractAddress, amount: u256) {
            assert(get_caller_address() == self.permitted_minter.read(), 'MINTER_ONLY');
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            unsafe_state._mint::<ERC20VotesHooksImpl>(recipient: account, :amount);
        }
        fn permissioned_burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            assert(get_caller_address() == self.permitted_minter.read(), 'MINTER_ONLY');
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            unsafe_state._burn::<ERC20VotesHooksImpl>(:account, :amount);
        }
    }

    fn calc_impl_key(implementation_data: ImplementationData) -> felt252 {
        // Hash the implementation_data to obtain a key.
        let mut hash_input = ArrayTrait::new();
        implementation_data.serialize(ref hash_input);
        poseidon::poseidon_hash_span(hash_input.span())
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
            self
                .emit(
                    Event::ImplementationAdded(
                        ImplementationAdded { implementation_data: implementation_data }
                    )
                );
        }

        fn remove_implementation(ref self: ContractState, implementation_data: ImplementationData) {
            self.only_upgrade_governor();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);

            if (impl_activation_time.is_non_zero()) {
                self.set_impl_activation_time(:implementation_data, activation_time: 0);
                self.set_impl_expiration_time(:implementation_data, expiration_time: 0);
                self
                    .emit(
                        Event::ImplementationRemoved(
                            ImplementationRemoved { implementation_data: implementation_data }
                        )
                    );
            }
        }
        // Replaces the non-finalized current implementation to one that was previously added and
        // whose activation time had passed.
        fn replace_to(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Validate implementation is not finalized.
            assert(!self.is_finalized(), 'FINALIZED');

            let now = get_block_timestamp();
            let impl_activation_time = self.get_impl_activation_time(:implementation_data);
            let impl_expiration_time = self.get_impl_expiration_time(:implementation_data);

            // Zero activation time means that this implementation & init vector combination
            // was not previously added.
            assert(impl_activation_time.is_non_zero(), 'UNKNOWN_IMPLEMENTATION');

            assert(impl_activation_time <= now, 'NOT_ENABLED_YET');
            assert(now <= impl_expiration_time, 'IMPLEMENTATION_EXPIRED');

            // We emit now so that finalize emits last (if it does).
            self
                .emit(
                    Event::ImplementationReplaced(ImplementationReplaced { implementation_data })
                );

            // Finalize imeplementation, if needed.
            if (implementation_data.final) {
                self.finalize();
                self
                    .emit(
                        Event::ImplementationFinalized(
                            ImplementationFinalized { impl_hash: implementation_data.impl_hash }
                        )
                    );
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
                    assert(res.is_ok(), 'EIC_LIB_CALL_FAILED');
                },
                Option::None(()) => {}
            };

            // Replace the class hash.
            let result = starknet::replace_class_syscall(implementation_data.impl_hash);
            assert(result.is_ok(), 'REPLACE_CLASSHASH_FAILED');

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
            assert(get_caller_address() == account, 'Can only renounce role for self');
            self._revoke_role(:role, :account);
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
            assert(role != GOVERNANCE_ADMIN, 'GOV_ADMIN_CANNOT_SELF_REMOVE');
            self.renounce_role(:role, account: get_caller_address())
        }
    }

    #[external(v0)]
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
            ERC20::InternalImpl::_transfer::<ERC20VotesHooksImpl>(
                ref unsafe_state, sender, recipient, amount
            );
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
            ERC20::InternalImpl::_transfer::<ERC20VotesHooksImpl>(
                ref unsafe_state, sender, recipient, amount
            );
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let mut unsafe_state = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::approve(ref unsafe_state, spender, amount)
        }
    }

    #[external(v0)]
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

    #[external(v0)]
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