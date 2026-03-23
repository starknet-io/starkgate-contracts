//! SPDX-License-Identifier: Apache-2.0.
//!
//! # ERC20 Votes Lock
//!
//! A voting wrapper contract that:
//! - Locks underlying tokens (STRK) and mints voting tokens 1:1
//! - Unlocks underlying tokens by burning voting tokens
//! - Provides delegation functionality for governance
//! - Role-based access control
//! - Replaceability (upgradeable with time delay)

#[starknet::contract]
pub mod ERC20VotesLock {
    use core::num::traits::Zero;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::governance::votes::VotesComponent;
    use openzeppelin::governance::votes::VotesComponent::InternalTrait as VotesInternalTrait;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::ERC20Component;
    use openzeppelin::token::erc20::ERC20Component::InternalTrait as ERC20InternalTrait;
    use openzeppelin::utils::nonces::NoncesComponent;
    use openzeppelin_interfaces::erc20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starkware_utils::components::common_roles::CommonRolesComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternalTrait;
    use strk::interfaces::{IMintableLock, ITokenLock, Locked, Unlocked};

    const DAPP_NAME: felt252 = 'TOKEN_DELEGATION';
    const DAPP_VERSION: felt252 = '1.0.0';

    // Components
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: VotesComponent, storage: votes, event: VotesEvent);
    component!(path: NoncesComponent, storage: nonces, event: NoncesEvent);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: CommonRolesComponent, storage: common_roles, event: CommonRolesEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);

    // External - ERC20 (camelCase compatibility)
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;

    // External - Votes
    #[abi(embed_v0)]
    impl VotesImpl = VotesComponent::VotesImpl<ContractState>;

    // External - Nonces
    #[abi(embed_v0)]
    impl NoncesImpl = NoncesComponent::NoncesImpl<ContractState>;

    // External - Roles
    #[abi(embed_v0)]
    impl GovernanceRolesImpl = RolesComponent::GovernanceRolesImpl<ContractState>;
    #[abi(embed_v0)]
    impl CommonRolesImpl = CommonRolesComponent::CommonRolesImpl<ContractState>;

    // External - Replaceability
    #[abi(embed_v0)]
    impl ReplaceabilityImpl =
        ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    // Internal impls (imported via traits)

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        votes: VotesComponent::Storage,
        #[substorage(v0)]
        nonces: NoncesComponent::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        common_roles: CommonRolesComponent::Storage,
        #[substorage(v0)]
        roles: RolesComponent::Storage,
        #[substorage(v0)]
        replaceability: ReplaceabilityComponent::Storage,
        // The underlying token that gets locked
        locked_token: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        VotesEvent: VotesComponent::Event,
        #[flat]
        NoncesEvent: NoncesComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        CommonRolesEvent: CommonRolesComponent::Event,
        #[flat]
        RolesEvent: RolesComponent::Event,
        #[flat]
        ReplaceabilityEvent: ReplaceabilityComponent::Event,
        Locked: Locked,
        Unlocked: Unlocked,
    }

    pub mod Errors {
        pub const INVALID_TOKEN: felt252 = 'INVALID_TOKEN';
        pub const INVALID_CALLER: felt252 = 'INVALID_CALLER';
    }

    // ERC20 ImmutableConfig - token always has 18 decimals (same as underlying STRK)
    impl ERC20ImmutableConfig of ERC20Component::ImmutableConfig {
        const DECIMALS: u8 = 18;
    }

    // SNIP12 Metadata for signature verification
    impl SNIP12MetadataImpl of openzeppelin::utils::cryptography::snip12::SNIP12Metadata {
        fn name() -> felt252 {
            DAPP_NAME
        }
        fn version() -> felt252 {
            DAPP_VERSION
        }
    }

    // Clock implementation for votes (timestamp-based)
    impl ClockImpl of openzeppelin::utils::contract_clock::ERC6372Clock {
        fn clock() -> u64 {
            starknet::get_block_timestamp()
        }
        fn CLOCK_MODE() -> ByteArray {
            "mode=timestamp"
        }
    }

    // Voting units implementation - voting power equals token balance
    impl VotingUnitsImpl of VotesComponent::VotingUnitsTrait<ContractState> {
        fn get_voting_units(self: @ContractState, account: ContractAddress) -> u256 {
            self.erc20.ERC20_balances.read(account)
        }
    }

    // ERC20 Hooks - transfer voting units after token transfers
    impl ERC20VotesHooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {}

        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            // Transfer voting units after token transfer
            let mut contract = self.get_contract_mut();
            contract.votes.transfer_voting_units(:from, to: recipient, :amount);
        }
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        locked_token: ContractAddress,
        provisional_governance_admin: ContractAddress,
        upgrade_delay: u64,
    ) {
        // Initialize ERC20
        self.erc20.initializer(:name, :symbol);

        // Set locked token
        assert(locked_token.is_non_zero(), Errors::INVALID_TOKEN);
        self.locked_token.write(locked_token);

        // Initialize roles
        self.roles.initialize(governance_admin: provisional_governance_admin);

        // Initialize replaceability
        self.replaceability.initialize(upgrade_delay);
    }

    // Mintable Lock - called by the underlying token during lock_and_delegate
    #[abi(embed_v0)]
    impl MintableLockImpl of IMintableLock<ContractState> {
        fn permissioned_lock_and_delegate(
            ref self: ContractState,
            account: ContractAddress,
            delegatee: ContractAddress,
            amount: u256,
        ) {
            // Only the locked token can call this
            assert(get_caller_address() == self.locked_token.read(), Errors::INVALID_CALLER);

            // Lock tokens and mint voting tokens
            self._lock(:account, :amount);

            // Delegate votes
            self.votes._delegate(:account, :delegatee);
        }
    }

    // Token Lock - direct lock/unlock
    #[abi(embed_v0)]
    impl TokenLockImpl of ITokenLock<ContractState> {
        fn lock(ref self: ContractState, amount: u256) {
            let account = get_caller_address();
            self._lock(:account, :amount);
        }

        fn unlock(ref self: ContractState, amount: u256) {
            let account = get_caller_address();
            self._unlock(:account, :amount);
        }
    }

    // Custom ERC20 implementation to use hooks
    #[abi(embed_v0)]
    impl ERC20Impl of openzeppelin_interfaces::erc20::IERC20<ContractState> {
        fn total_supply(self: @ContractState) -> u256 {
            self.erc20.total_supply()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.erc20.balance_of(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.erc20.allowance(:owner, :spender)
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            self.erc20.update(from: sender, to: recipient, :amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            self.erc20._spend_allowance(owner: sender, spender: caller, :amount);
            self.erc20.update(from: sender, to: recipient, :amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.erc20._approve(owner: caller, :spender, :amount);
            true
        }
    }

    // Allowance helpers
    #[external(v0)]
    fn increase_allowance(
        ref self: ContractState, spender: ContractAddress, added_value: u256,
    ) -> bool {
        let caller = get_caller_address();
        let current = self.erc20.allowance(owner: caller, :spender);
        self.erc20._approve(owner: caller, :spender, amount: current + added_value);
        true
    }

    #[external(v0)]
    fn decrease_allowance(
        ref self: ContractState, spender: ContractAddress, subtracted_value: u256,
    ) -> bool {
        let caller = get_caller_address();
        let current = self.erc20.allowance(owner: caller, :spender);
        self.erc20._approve(owner: caller, :spender, amount: current - subtracted_value);
        true
    }

    #[external(v0)]
    fn increaseAllowance(
        ref self: ContractState, spender: ContractAddress, addedValue: u256,
    ) -> bool {
        increase_allowance(ref self, :spender, added_value: addedValue)
    }

    #[external(v0)]
    fn decreaseAllowance(
        ref self: ContractState, spender: ContractAddress, subtractedValue: u256,
    ) -> bool {
        decrease_allowance(ref self, :spender, subtracted_value: subtractedValue)
    }

    // Checkpoint functions for ABI compatibility (original used u32, OZ 3.0 uses u64)
    #[external(v0)]
    fn num_checkpoints(self: @ContractState, account: ContractAddress) -> u32 {
        let count: u64 = self.votes.num_checkpoints(:account);
        count.try_into().expect('num_checkpoints overflow')
    }

    #[external(v0)]
    fn checkpoints(
        self: @ContractState, account: ContractAddress, pos: u32,
    ) -> openzeppelin::utils::structs::checkpoint::Checkpoint {
        let pos_u64: u64 = pos.into();
        self.votes.checkpoints(:account, pos: pos_u64)
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _lock(ref self: ContractState, account: ContractAddress, amount: u256) {
            let this = get_contract_address();
            let locked_token = self.locked_token.read();

            // Transfer underlying tokens from account to this contract
            IERC20Dispatcher { contract_address: locked_token }
                .transfer_from(sender: account, recipient: this, :amount);

            // Mint voting tokens
            self.erc20.mint(recipient: account, :amount);

            self.emit(Locked { account, amount });
        }

        fn _unlock(ref self: ContractState, account: ContractAddress, amount: u256) {
            let locked_token = self.locked_token.read();

            // Burn voting tokens
            self.erc20.burn(:account, :amount);

            // Transfer underlying tokens back to account
            IERC20Dispatcher { contract_address: locked_token }
                .transfer(recipient: account, :amount);

            self.emit(Unlocked { account, amount });
        }
    }
}
