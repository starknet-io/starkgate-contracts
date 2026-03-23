//! SPDX-License-Identifier: Apache-2.0.
//!
//! # ERC20 Lockable Token (STRK)
//!
//! An ERC20 token with:
//! - Permissioned minting/burning
//! - Lock and delegate functionality with EIP712 signature support
//! - Role-based access control
//! - Replaceability (upgradeable with time delay)

#[starknet::contract]
pub mod ERC20Lockable {
    use core::num::traits::{Bounded, Zero};
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use openzeppelin_interfaces::erc20::IERC20Metadata;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use starkware_utils::components::common_roles::CommonRolesComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternalTrait;
    use starkware_utils::interfaces::mintable_token::{IMintableToken, IMintableTokenCamelOnly};
    use strk::eip712_utils::{calc_domain_hash, lock_and_delegate_message_hash, validate_signature};
    use strk::interfaces::{
        ILockAndDelegate, ILockingContract, IMintableLockDispatcher, IMintableLockDispatcherTrait,
    };

    // Components
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: CommonRolesComponent, storage: common_roles, event: CommonRolesEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);

    // External - ERC20
    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;

    // External - Roles
    #[abi(embed_v0)]
    impl GovernanceRolesImpl = RolesComponent::GovernanceRolesImpl<ContractState>;
    #[abi(embed_v0)]
    impl CommonRolesImpl = CommonRolesComponent::CommonRolesImpl<ContractState>;

    // External - Replaceability
    #[abi(embed_v0)]
    impl ReplaceabilityImpl =
        ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    // Internal
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        // --- Components ---
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
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
        // --- Token specific ---
        // Note: Named ERC20_decimals for storage compatibility with legacy contracts
        ERC20_decimals: u8,
        permitted_minter: ContractAddress,
        // --- Lock and Delegate ---
        locking_contract: ContractAddress,
        recorded_locks: Map<felt252, bool>,
        domain_hash: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
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
    }

    pub mod Errors {
        pub const INVALID_MINTER: felt252 = 'INVALID_MINTER_ADDRESS';
        pub const ONLY_MINTER: felt252 = 'ONLY_MINTER';
        pub const LOCKING_CONTRACT_ALREADY_SET: felt252 = 'LOCKING_CONTRACT_ALREADY_SET';
        pub const LOCKING_CONTRACT_NOT_SET: felt252 = 'LOCKING_CONTRACT_NOT_SET';
        pub const ZERO_ADDRESS: felt252 = 'ZERO_ADDRESS';
        pub const SIGNATURE_EXPIRED: felt252 = 'SIGNATURE_EXPIRED';
        pub const SIGNED_REQUEST_ALREADY_USED: felt252 = 'SIGNED_REQUEST_ALREADY_USED';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        initial_supply: u256,
        recipient: ContractAddress,
        permitted_minter: ContractAddress,
        provisional_governance_admin: ContractAddress,
        upgrade_delay: u64,
    ) {
        // Initialize ERC20
        self.erc20.initializer(:name, :symbol);
        self.ERC20_decimals.write(decimals);

        // Mint initial supply
        if initial_supply > 0 {
            self.erc20.mint(:recipient, amount: initial_supply);
        }

        // Initialize permitted minter
        assert(permitted_minter.is_non_zero(), Errors::INVALID_MINTER);
        self.permitted_minter.write(permitted_minter);

        // Initialize roles
        self.roles.initialize(governance_admin: provisional_governance_admin);

        // Initialize replaceability
        self.replaceability.initialize(upgrade_delay);

        // Initialize domain hash for EIP712
        self.domain_hash.write(calc_domain_hash());
    }

    // Custom decimals implementation
    #[abi(embed_v0)]
    impl ERC20MetadataImpl of IERC20Metadata<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_name.read()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.ERC20_decimals.read()
        }
    }

    // Locking contract management
    #[abi(embed_v0)]
    impl LockingContractImpl of ILockingContract<ContractState> {
        fn set_locking_contract(ref self: ContractState, locking_contract: ContractAddress) {
            self.roles.only_upgrade_governor();
            assert(self.locking_contract.read().is_zero(), Errors::LOCKING_CONTRACT_ALREADY_SET);
            assert(locking_contract.is_non_zero(), Errors::ZERO_ADDRESS);
            self.locking_contract.write(locking_contract);
        }

        fn get_locking_contract(self: @ContractState) -> ContractAddress {
            self.locking_contract.read()
        }
    }

    // Lock and delegate
    #[abi(embed_v0)]
    impl LockAndDelegateImpl of ILockAndDelegate<ContractState> {
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
            signature: Array<felt252>,
        ) {
            assert(get_block_timestamp() <= expiry, Errors::SIGNATURE_EXPIRED);

            let domain = self.domain_hash.read();
            let hash = lock_and_delegate_message_hash(
                :domain, :account, :delegatee, :amount, :nonce, :expiry,
            );

            // Assert this signed request was not used
            let is_known_hash = self.recorded_locks.read(hash);
            assert(!is_known_hash, Errors::SIGNED_REQUEST_ALREADY_USED);

            // Mark the request as used to prevent future replay
            self.recorded_locks.write(hash, true);

            validate_signature(:account, :hash, :signature);
            self._lock_and_delegate(:account, :delegatee, :amount);
        }
    }

    // Mintable token
    #[abi(embed_v0)]
    impl MintableTokenImpl of IMintableToken<ContractState> {
        fn permissioned_mint(ref self: ContractState, account: ContractAddress, amount: u256) {
            self.only_minter();
            self.erc20.mint(recipient: account, :amount);
        }

        fn permissioned_burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            self.only_minter();
            self.erc20.burn(:account, :amount);
        }

        fn is_permitted_minter(self: @ContractState, account: ContractAddress) -> bool {
            account == self.permitted_minter.read()
        }
    }

    // Mintable token (camelCase for ABI compatibility)
    #[abi(embed_v0)]
    impl MintableTokenCamelImpl of IMintableTokenCamelOnly<ContractState> {
        fn permissionedMint(ref self: ContractState, account: ContractAddress, amount: u256) {
            MintableTokenImpl::permissioned_mint(ref self, :account, :amount);
        }

        fn permissionedBurn(ref self: ContractState, account: ContractAddress, amount: u256) {
            MintableTokenImpl::permissioned_burn(ref self, :account, :amount);
        }

        fn isPermittedMinter(self: @ContractState, account: ContractAddress) -> bool {
            MintableTokenImpl::is_permitted_minter(self, :account)
        }
    }

    /// L1 Handler for approving L1 addresses (rescue mechanism)
    /// Allows an L1 address owner to approve a spender to rescue funds locked in that address
    #[l1_handler]
    fn approve_l1_address(
        ref self: ContractState, from_address: felt252, spender: ContractAddress,
    ) {
        let owner: ContractAddress = from_address.try_into().unwrap();
        let amount = self.erc20.balance_of(account: owner);
        self.erc20._approve(:owner, :spender, :amount);
    }

    // Allowance helpers (snake_case)
    #[external(v0)]
    fn increase_allowance(
        ref self: ContractState, spender: ContractAddress, added_value: u256,
    ) -> bool {
        self._increase_allowance(:spender, :added_value)
    }

    #[external(v0)]
    fn decrease_allowance(
        ref self: ContractState, spender: ContractAddress, subtracted_value: u256,
    ) -> bool {
        self._decrease_allowance(:spender, :subtracted_value)
    }

    // Allowance helpers (camelCase)
    #[external(v0)]
    fn increaseAllowance(
        ref self: ContractState, spender: ContractAddress, addedValue: u256,
    ) -> bool {
        self._increase_allowance(:spender, added_value: addedValue)
    }

    #[external(v0)]
    fn decreaseAllowance(
        ref self: ContractState, spender: ContractAddress, subtractedValue: u256,
    ) -> bool {
        self._decrease_allowance(:spender, subtracted_value: subtractedValue)
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn only_minter(self: @ContractState) {
            assert(get_caller_address() == self.permitted_minter.read(), Errors::ONLY_MINTER);
        }

        fn _lock_and_delegate(
            ref self: ContractState,
            account: ContractAddress,
            delegatee: ContractAddress,
            amount: u256,
        ) {
            let locking_contract = self.locking_contract.read();
            assert(locking_contract.is_non_zero(), Errors::LOCKING_CONTRACT_NOT_SET);

            // Increase allowance for the locking contract
            self._increase_account_allowance(:account, spender: locking_contract, :amount);

            // Call the locking contract
            IMintableLockDispatcher { contract_address: locking_contract }
                .permissioned_lock_and_delegate(:account, :delegatee, :amount);
        }

        fn _increase_account_allowance(
            ref self: ContractState,
            account: ContractAddress,
            spender: ContractAddress,
            amount: u256,
        ) {
            let current_allowance = self.erc20.ERC20_allowances.read((account, spender));
            // Skip if allowance + amount would exceed max_uint
            if current_allowance <= Bounded::MAX - amount {
                self.erc20._approve(owner: account, :spender, amount: current_allowance + amount);
            }
        }

        fn _increase_allowance(
            ref self: ContractState, spender: ContractAddress, added_value: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_allowance = self.erc20.ERC20_allowances.read((caller, spender));
            self.erc20._approve(owner: caller, :spender, amount: current_allowance + added_value);
            true
        }

        fn _decrease_allowance(
            ref self: ContractState, spender: ContractAddress, subtracted_value: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_allowance = self.erc20.ERC20_allowances.read((caller, spender));
            self
                .erc20
                ._approve(owner: caller, :spender, amount: current_allowance - subtracted_value);
            true
        }
    }
}
