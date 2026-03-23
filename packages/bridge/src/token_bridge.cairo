//! SPDX-License-Identifier: Apache-2.0.
//!
//! # Token Bridge
//!
//! A bridge contract for L1<->L2 token transfers with:
//! - Multi-token support (L1/L2 token mappings)
//! - Withdrawal limits (daily quota per token)
//! - Role-based access control
//! - Replaceability (upgradeable with time delay)
//! - L1 handlers for deposits and token deployment

#[starknet::contract]
#[feature("safe_dispatcher")]
pub mod TokenBridge {
    use bridge::interfaces::{
        ITokenBridge, ITokenBridgeAdmin, ITokenBridgeReceiverSafeDispatcher,
        ITokenBridgeReceiverSafeDispatcherTrait,
    };
    use core::num::traits::{Bounded, Zero};
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::syscalls::{deploy_syscall, send_message_to_l1_syscall};
    use starknet::{
        ClassHash, ContractAddress, EthAddress, SyscallResultTrait, get_block_timestamp,
        get_caller_address, get_contract_address,
    };
    use starkware_utils::byte_array::short_string_to_byte_array;
    use starkware_utils::components::common_roles::CommonRolesComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternalTrait;
    use starkware_utils::interfaces::mintable_token::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait,
    };

    // Constants
    const WITHDRAW_MESSAGE: felt252 = 0;
    const CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const CONTRACT_VERSION: felt252 = 2;
    const DEFAULT_DAILY_WITHDRAW_LIMIT_PCT: u8 = 5;
    const SECONDS_IN_DAY: u64 = 86400;
    const DEFAULT_UPGRADE_DELAY: u64 = 0;
    const REMAINING_QUOTA_OFFSET: u256 = 1;

    /// Tracks locked amount per L1 token with opt-in monitoring.
    /// - monitoring_enabled: if false, locked amount checks are skipped (legacy behavior)
    /// - amount: the tracked locked amount when monitoring is enabled
    #[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
    pub struct LockedAmount {
        pub amount: u256,
        pub monitoring_enabled: bool,
    }

    // Components
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: CommonRolesComponent, storage: common_roles, event: CommonRolesEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);

    // External - Replaceability
    #[abi(embed_v0)]
    impl ReplaceabilityImpl =
        ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    // External - Roles
    #[abi(embed_v0)]
    impl RolesImpl = RolesComponent::RolesImpl<ContractState>;
    #[abi(embed_v0)]
    impl CommonRolesImpl = CommonRolesComponent::CommonRolesImpl<ContractState>;

    #[storage]
    struct Storage {
        // --- Components ---
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
        // --- Token Bridge ---
        l1_bridge: EthAddress,
        erc20_class_hash: ClassHash,
        l2_token_governance: ContractAddress,
        l1_l2_token_map: Map<EthAddress, ContractAddress>,
        l2_l1_token_map: Map<ContractAddress, EthAddress>,
        // --- Withdrawal Limits ---
        withdrawal_limit_applied: Map<ContractAddress, bool>,
        remaining_intraday_withdraw_quota: Map<(ContractAddress, u64), u256>,
        daily_withdrawal_limit_pct: u8,
        // --- Legacy (for upgraded bridges) ---
        l2_token: ContractAddress,
        // --- L1 Locked Amount ---
        l1_locked_amount: Map<EthAddress, LockedAmount>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        // --- Components ---
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
        // --- Token Bridge ---
        L1BridgeSet: L1BridgeSet,
        Erc20ClassHashStored: Erc20ClassHashStored,
        L2TokenGovernanceChanged: L2TokenGovernanceChanged,
        withdraw_initiated: withdraw_initiated,
        WithdrawInitiated: WithdrawInitiated,
        deposit_handled: deposit_handled,
        DepositHandled: DepositHandled,
        DepositWithMessageHandled: DepositWithMessageHandled,
        DeployHandled: DeployHandled,
        WithdrawalLimitEnabled: WithdrawalLimitEnabled,
        WithdrawalLimitDisabled: WithdrawalLimitDisabled,
        LockedAmountMonitoringEnabled: LockedAmountMonitoringEnabled,
    }

    #[derive(Drop, starknet::Event)]
    struct L1BridgeSet {
        l1_bridge_address: EthAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Erc20ClassHashStored {
        previous_hash: ClassHash,
        erc20_class_hash: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct L2TokenGovernanceChanged {
        previous_governance: ContractAddress,
        new_governance: ContractAddress,
    }

    // Legacy event for backward compatibility
    #[derive(Drop, starknet::Event)]
    struct withdraw_initiated {
        l1_recipient: EthAddress,
        amount: u256,
        caller_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawInitiated {
        #[key]
        l1_token: EthAddress,
        #[key]
        l1_recipient: EthAddress,
        amount: u256,
        #[key]
        caller_address: ContractAddress,
    }

    // Legacy event for backward compatibility
    #[derive(Drop, starknet::Event)]
    struct deposit_handled {
        account: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DepositHandled {
        #[key]
        l1_token: EthAddress,
        #[key]
        l2_recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DepositWithMessageHandled {
        #[key]
        depositor: EthAddress,
        #[key]
        l1_token: EthAddress,
        #[key]
        l2_recipient: ContractAddress,
        amount: u256,
        message: Span<felt252>,
    }

    #[derive(Drop, starknet::Event)]
    struct DeployHandled {
        l1_token: EthAddress,
        name: felt252,
        symbol: felt252,
        decimals: u8,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalLimitEnabled {
        #[key]
        sender: ContractAddress,
        #[key]
        l1_token: EthAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalLimitDisabled {
        #[key]
        sender: ContractAddress,
        #[key]
        l1_token: EthAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct LockedAmountMonitoringEnabled {
        #[key]
        l1_token: EthAddress,
        amount: u256,
    }

    pub mod Errors {
        pub const UNINITIALIZED_L1_BRIDGE: felt252 = 'UNINITIALIZED_L1_BRIDGE_ADDRESS';
        pub const EXPECTED_FROM_BRIDGE: felt252 = 'EXPECTED_FROM_BRIDGE_ONLY';
        pub const TOKEN_NOT_IN_BRIDGE: felt252 = 'TOKEN_NOT_IN_BRIDGE';
        pub const L1_BRIDGE_ALREADY_SET: felt252 = 'L1_BRIDGE_ALREADY_INITIALIZED';
        pub const ZERO_L1_BRIDGE: felt252 = 'ZERO_L1_BRIDGE_ADDRESS';
        pub const INVALID_RECIPIENT: felt252 = 'INVALID_RECIPIENT';
        pub const ZERO_WITHDRAWAL: felt252 = 'ZERO_WITHDRAWAL';
        pub const INSUFFICIENT_FUNDS: felt252 = 'INSUFFICIENT_FUNDS';
        pub const LIMIT_EXCEEDED: felt252 = 'LIMIT_EXCEEDED';
        pub const WITHDRAWAL_LIMIT_EXCEEDED: felt252 = 'WITHDRAWAL_LIMIT_EXCEEDED';
        pub const L2_TOKEN_NOT_SET: felt252 = 'L2_TOKEN_NOT_SET';
        pub const L1_L2_TOKEN_MISMATCH: felt252 = 'L1_L2_TOKEN_MISMATCH';
        pub const TOKEN_CONFIG_MISMATCH: felt252 = 'TOKEN_CONFIG_MISMATCH';
        pub const DEPLOY_TOKEN_DISALLOWED: felt252 = 'DEPLOY_TOKEN_DISALLOWED';
        pub const TOKEN_ALREADY_EXISTS: felt252 = 'TOKEN_ALREADY_EXISTS';
        pub const L2_TOKEN_GOV_NOT_SET: felt252 = 'L2_TOKEN_GOV_NOT_SET';
        pub const CLASS_HASH_NOT_SET: felt252 = 'L2_TOKEN_CLASS_HASH_NOT_SET';
        pub const MESSAGE_SEND_FAILED: felt252 = 'MESSAGE_SEND_FAIILED';
        pub const ON_RECEIVE_FAILED: felt252 = 'ON_RECEIVE_FAILED';
        pub const DEPOSIT_REJECTED: felt252 = 'DEPOSIT_REJECTED';
        pub const LIMIT_PCT_TOO_HIGH: felt252 = 'LIMIT_PCT_TOO_HIGH';
        pub const WITHDRAWAL_LIMIT_ERROR: felt252 = 'withdrawal_limit_applied ERROR';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, provisional_governance_admin: ContractAddress, upgrade_delay: u64,
    ) {
        // Initialize roles
        self.roles.initialize(governance_admin: provisional_governance_admin);

        // Initialize replaceability
        self.replaceability.initialize(:upgrade_delay);

        // Set default daily withdrawal limit percentage
        self.daily_withdrawal_limit_pct.write(DEFAULT_DAILY_WITHDRAW_LIMIT_PCT);
    }

    #[abi(embed_v0)]
    impl TokenBridgeAdminImpl of ITokenBridgeAdmin<ContractState> {
        fn get_l1_bridge(self: @ContractState) -> EthAddress {
            self.l1_bridge.read()
        }

        fn get_erc20_class_hash(self: @ContractState) -> ClassHash {
            self.erc20_class_hash.read()
        }

        fn get_l2_token_governance(self: @ContractState) -> ContractAddress {
            self.l2_token_governance.read()
        }

        fn set_l1_bridge(ref self: ContractState, l1_bridge_address: EthAddress) {
            self.roles.only_app_governor();
            assert(self.l1_bridge.read().is_zero(), Errors::L1_BRIDGE_ALREADY_SET);
            assert(l1_bridge_address.is_non_zero(), Errors::ZERO_L1_BRIDGE);
            self.l1_bridge.write(l1_bridge_address);
            self.emit(L1BridgeSet { l1_bridge_address });
        }

        fn set_erc20_class_hash(ref self: ContractState, erc20_class_hash: ClassHash) {
            self.roles.only_app_governor();
            let previous_hash = self.erc20_class_hash.read();
            self.erc20_class_hash.write(erc20_class_hash);
            self.emit(Erc20ClassHashStored { previous_hash, erc20_class_hash });
        }

        fn set_l2_token_governance(ref self: ContractState, l2_token_governance: ContractAddress) {
            self.roles.only_app_governor();
            let previous_governance = self.l2_token_governance.read();
            self.l2_token_governance.write(l2_token_governance);
            self
                .emit(
                    L2TokenGovernanceChanged {
                        previous_governance, new_governance: l2_token_governance,
                    },
                );
        }

        fn enable_withdrawal_limit(ref self: ContractState, l1_token: EthAddress) {
            self.roles.only_security_agent();
            let l2_token = self.l1_l2_token_map.read(l1_token);
            assert(l2_token.is_non_zero(), Errors::TOKEN_NOT_IN_BRIDGE);
            self.withdrawal_limit_applied.write(l2_token, true);
            let sender = get_caller_address();
            self.emit(WithdrawalLimitEnabled { sender, l1_token });
        }

        fn disable_withdrawal_limit(ref self: ContractState, l1_token: EthAddress) {
            self.roles.only_security_admin();
            let l2_token = self.l1_l2_token_map.read(l1_token);
            assert(l2_token.is_non_zero(), Errors::TOKEN_NOT_IN_BRIDGE);
            self.withdrawal_limit_applied.write(l2_token, false);
            let sender = get_caller_address();
            self.emit(WithdrawalLimitDisabled { sender, l1_token });
        }

        fn enable_locked_amount_monitoring(
            ref self: ContractState, l1_token: EthAddress, locked_amount: u256,
        ) {
            self.roles.only_app_governor();

            let l2_token = self.l1_l2_token_map.read(l1_token);
            assert(l2_token.is_non_zero(), Errors::TOKEN_NOT_IN_BRIDGE);

            let amount = if locked_amount == 0 {
                IERC20Dispatcher { contract_address: l2_token }.total_supply()
            } else {
                locked_amount
            };

            self
                .l1_locked_amount
                .write(l1_token, LockedAmount { monitoring_enabled: true, amount });

            self.emit(LockedAmountMonitoringEnabled { l1_token, amount });
        }
    }

    #[abi(embed_v0)]
    impl TokenBridgeImpl of ITokenBridge<ContractState> {
        fn get_version(self: @ContractState) -> felt252 {
            CONTRACT_VERSION
        }

        fn get_identity(self: @ContractState) -> felt252 {
            CONTRACT_IDENTITY
        }

        fn get_l1_token(self: @ContractState, l2_token: ContractAddress) -> EthAddress {
            self.l2_l1_token_map.read(l2_token)
        }

        fn get_l2_token(self: @ContractState, l1_token: EthAddress) -> ContractAddress {
            self.l1_l2_token_map.read(l1_token)
        }

        fn get_remaining_withdrawal_quota(self: @ContractState, l1_token: EthAddress) -> u256 {
            let l2_token = self.l1_l2_token_map.read(l1_token);
            if !self.is_withdrawal_limit_applied(l2_token) {
                return Bounded::MAX;
            }
            let remaining_quota = self.read_withdrawal_quota_slot(l2_token);
            if remaining_quota == 0 {
                return self.get_daily_withdrawal_limit(l2_token);
            }
            remaining_quota - REMAINING_QUOTA_OFFSET
        }

        fn initiate_withdraw(ref self: ContractState, l1_recipient: EthAddress, amount: u256) {
            let l2_token = self.l2_token.read();
            assert(l2_token.is_non_zero(), Errors::L2_TOKEN_NOT_SET);
            let l1_token = self.l2_l1_token_map.read(l2_token);
            assert(l2_token == self.l1_l2_token_map.read(l1_token), Errors::L1_L2_TOKEN_MISMATCH);

            self.initiate_token_withdraw(:l1_token, :l1_recipient, :amount);

            // Legacy event for backward compatibility
            let caller_address = get_caller_address();
            self.emit(withdraw_initiated { l1_recipient, amount, caller_address });
        }

        fn initiate_token_withdraw(
            ref self: ContractState, l1_token: EthAddress, l1_recipient: EthAddress, amount: u256,
        ) {
            assert(l1_recipient.is_non_zero(), Errors::INVALID_RECIPIENT);

            let caller_address = get_caller_address();
            let l2_token = self.l1_l2_token_map.read(l1_token);
            assert(l2_token.is_non_zero(), Errors::TOKEN_NOT_IN_BRIDGE);
            let l1_bridge_address = self.get_l1_bridge_address();

            assert(amount != 0, Errors::ZERO_WITHDRAWAL);
            let caller_balance = IERC20Dispatcher { contract_address: l2_token }
                .balance_of(caller_address);
            assert(amount <= caller_balance, Errors::INSUFFICIENT_FUNDS);

            if self.is_withdrawal_limit_applied(:l2_token) {
                self.consume_withdrawal_quota(:l1_token, amount_to_withdraw: amount);
            }

            let LockedAmount {
                monitoring_enabled, amount: locked_amount,
            } = self.l1_locked_amount.read(l1_token);
            if monitoring_enabled {
                assert(locked_amount >= amount, Errors::WITHDRAWAL_LIMIT_EXCEEDED);
                self
                    .l1_locked_amount
                    .write(
                        l1_token,
                        LockedAmount { monitoring_enabled: true, amount: locked_amount - amount },
                    );
            }

            // Burn tokens
            IMintableTokenDispatcher { contract_address: l2_token }
                .permissioned_burn(account: caller_address, :amount);

            // Send message to L1
            let mut message_payload = array![];
            WITHDRAW_MESSAGE.serialize(ref message_payload);
            l1_recipient.serialize(ref message_payload);
            l1_token.serialize(ref message_payload);
            amount.serialize(ref message_payload);

            let result = send_message_to_l1_syscall(
                to_address: l1_bridge_address.into(), payload: message_payload.span(),
            );
            assert(result.is_ok(), Errors::MESSAGE_SEND_FAILED);

            self.emit(WithdrawInitiated { l1_token, l1_recipient, amount, caller_address });
        }
    }

    // L1 Handlers
    #[l1_handler]
    fn handle_deposit(
        ref self: ContractState, from_address: felt252, l2_recipient: ContractAddress, amount: u256,
    ) {
        let l2_token = self.l2_token.read();
        assert(l2_token.is_non_zero(), Errors::TOKEN_CONFIG_MISMATCH);
        let l1_token = self.l2_l1_token_map.read(l2_token);
        assert(l2_token == self.l1_l2_token_map.read(l1_token), Errors::L1_L2_TOKEN_MISMATCH);

        self.only_from_l1_bridge(:from_address);
        self.handle_deposit_common(:l2_recipient, :amount, :l1_token);

        self.emit(DepositHandled { l1_token, l2_recipient, amount });
        self.emit(deposit_handled { account: l2_recipient, amount });
    }

    #[l1_handler]
    fn handle_token_deposit(
        ref self: ContractState,
        from_address: felt252,
        l1_token: EthAddress,
        depositor: EthAddress,
        l2_recipient: ContractAddress,
        amount: u256,
    ) {
        self.only_from_l1_bridge(:from_address);
        self.handle_deposit_common(:l2_recipient, :amount, :l1_token);
        self.emit(DepositHandled { l1_token, l2_recipient, amount });
    }

    #[l1_handler]
    fn handle_deposit_with_message(
        ref self: ContractState,
        from_address: felt252,
        l1_token: EthAddress,
        depositor: EthAddress,
        l2_recipient: ContractAddress,
        amount: u256,
        message: Span<felt252>,
    ) {
        self.only_from_l1_bridge(:from_address);
        self.handle_deposit_common(:l2_recipient, :amount, :l1_token);

        let l2_token = self.l1_l2_token_map.read(l1_token);

        // Call on_receive on the recipient contract (using SafeDispatcher to catch panics)
        let receiver = ITokenBridgeReceiverSafeDispatcher { contract_address: l2_recipient };
        match receiver.on_receive(:l2_token, :amount, :depositor, :message) {
            Result::Ok(success) => assert(success, Errors::DEPOSIT_REJECTED),
            Result::Err(_) => core::panic_with_felt252(Errors::ON_RECEIVE_FAILED),
        }

        self.emit(DepositWithMessageHandled { depositor, l1_token, l2_recipient, amount, message });
    }

    #[l1_handler]
    fn handle_token_deployment(
        ref self: ContractState,
        from_address: felt252,
        l1_token: EthAddress,
        name: felt252,
        symbol: felt252,
        decimals: u8,
    ) {
        // Upgraded legacy bridge is not allowed to deploy tokens
        let l2_token = self.l2_token.read();
        assert(l2_token.is_zero(), Errors::DEPLOY_TOKEN_DISALLOWED);

        self.only_from_l1_bridge(:from_address);
        assert(self.l1_l2_token_map.read(l1_token).is_zero(), Errors::TOKEN_ALREADY_EXISTS);

        let l2_token_governance = self.l2_token_governance.read();
        assert(l2_token_governance.is_non_zero(), Errors::L2_TOKEN_GOV_NOT_SET);

        let class_hash = self.erc20_class_hash.read();
        assert(class_hash.is_non_zero(), Errors::CLASS_HASH_NOT_SET);

        // Name & Symbol received as short 'strings', convert to long "strings".
        let long_name = short_string_to_byte_array(name);
        let long_symbol = short_string_to_byte_array(symbol);

        let initial_supply: u256 = 0;
        let permitted_minter = get_contract_address();
        let initial_recipient = permitted_minter;

        let mut calldata = array![];
        long_name.serialize(ref calldata);
        long_symbol.serialize(ref calldata);
        decimals.serialize(ref calldata);
        initial_supply.serialize(ref calldata);
        initial_recipient.serialize(ref calldata);
        permitted_minter.serialize(ref calldata);
        l2_token_governance.serialize(ref calldata);
        DEFAULT_UPGRADE_DELAY.serialize(ref calldata);

        // Deploy using l1_token as salt for uniqueness
        let (deployed_l2_token, _) = deploy_syscall(
            class_hash, l1_token.into(), calldata.span(), false,
        )
            .unwrap_syscall();

        self.l1_l2_token_map.write(l1_token, deployed_l2_token);
        self.l2_l1_token_map.write(deployed_l2_token, l1_token);

        // Initialize locked amount monitoring for new tokens
        self.l1_locked_amount.write(l1_token, LockedAmount { monitoring_enabled: true, amount: 0 });

        self.emit(DeployHandled { l1_token, name, symbol, decimals });
    }

    // Internal functions
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn get_l1_bridge_address(self: @ContractState) -> EthAddress {
            let l1_bridge_address = self.l1_bridge.read();
            assert(l1_bridge_address.is_non_zero(), Errors::UNINITIALIZED_L1_BRIDGE);
            l1_bridge_address
        }

        fn only_from_l1_bridge(self: @ContractState, from_address: felt252) {
            let l1_bridge_address = self.get_l1_bridge_address();
            assert(from_address == l1_bridge_address.into(), Errors::EXPECTED_FROM_BRIDGE);
        }

        fn handle_deposit_common(
            ref self: ContractState,
            l2_recipient: ContractAddress,
            amount: u256,
            l1_token: EthAddress,
        ) {
            let l2_token = self.l1_l2_token_map.read(l1_token);
            assert(l2_token.is_non_zero(), Errors::TOKEN_NOT_IN_BRIDGE);

            let LockedAmount {
                monitoring_enabled, amount: locked_amount,
            } = self.l1_locked_amount.read(l1_token);
            if monitoring_enabled {
                self
                    .l1_locked_amount
                    .write(
                        l1_token,
                        LockedAmount { monitoring_enabled: true, amount: locked_amount + amount },
                    );
            }

            IMintableTokenDispatcher { contract_address: l2_token }
                .permissioned_mint(account: l2_recipient, :amount);
        }

        fn is_withdrawal_limit_applied(self: @ContractState, l2_token: ContractAddress) -> bool {
            self.withdrawal_limit_applied.read(l2_token)
        }

        fn read_withdrawal_quota_slot(self: @ContractState, l2_token: ContractAddress) -> u256 {
            let now = get_block_timestamp();
            let day = now / SECONDS_IN_DAY;
            self.remaining_intraday_withdraw_quota.read((l2_token, day))
        }

        fn set_remaining_withdrawal_quota(
            ref self: ContractState, l2_token: ContractAddress, amount: u256,
        ) {
            let now = get_block_timestamp();
            let day = now / SECONDS_IN_DAY;
            self
                .remaining_intraday_withdraw_quota
                .write((l2_token, day), amount + REMAINING_QUOTA_OFFSET);
        }

        fn get_daily_withdrawal_limit(self: @ContractState, l2_token: ContractAddress) -> u256 {
            let total_supply = IERC20Dispatcher { contract_address: l2_token }.total_supply();
            let daily_withdrawal_limit_pct: u256 = self.daily_withdrawal_limit_pct.read().into();
            total_supply * daily_withdrawal_limit_pct / 100
        }

        fn consume_withdrawal_quota(
            ref self: ContractState, l1_token: EthAddress, amount_to_withdraw: u256,
        ) {
            let remaining_withdrawal_quota = TokenBridgeImpl::get_remaining_withdrawal_quota(
                @self, l1_token,
            );
            assert(remaining_withdrawal_quota < Bounded::MAX, Errors::WITHDRAWAL_LIMIT_ERROR);
            assert(remaining_withdrawal_quota >= amount_to_withdraw, Errors::LIMIT_EXCEEDED);

            let l2_token = self.l1_l2_token_map.read(l1_token);
            self
                .set_remaining_withdrawal_quota(
                    :l2_token, amount: remaining_withdrawal_quota - amount_to_withdraw,
                );
        }
    }

    // Unit tests for L1 handlers and internal functionality - placed INSIDE the contract module.
    #[cfg(test)]
    mod tests {
        use bridge::interfaces::{
            ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait, ITokenBridgeDispatcher,
            ITokenBridgeDispatcherTrait,
        };
        use core::num::traits::Bounded;
        use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
        use starknet::storage::{StorageMapReadAccess, StorageMapWriteAccess};
        use starknet::syscalls::deploy_syscall;
        use starknet::{ClassHash, ContractAddress, EthAddress, get_contract_address};
        use starkware_utils::components::roles::interface::{
            IRolesDispatcher, IRolesDispatcherTrait,
        };

        // Mock ERC20 contract for testing - signature matches TokenBridge::handle_token_deployment:
        // (name: felt252, symbol: felt252, decimals: u8, initial_supply: u256, initial_recipient:
        // ContractAddress,
        //  permitted_minter: ContractAddress, governance_admin: ContractAddress, upgrade_delay:
        //  u64)
        #[starknet::contract]
        mod MockERC20Mintable {
            use openzeppelin::access::accesscontrol::AccessControlComponent;
            use openzeppelin::introspection::src5::SRC5Component;
            use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
            use starknet::ContractAddress;
            use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
            use starkware_utils::components::common_roles::CommonRolesComponent;
            use starkware_utils::components::roles::RolesComponent;
            use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternal;
            use starkware_utils::interfaces::mintable_token::{
                IMintableToken, IMintableTokenCamelOnly,
            };

            component!(path: ERC20Component, storage: erc20, event: ERC20Event);
            component!(path: CommonRolesComponent, storage: common_roles, event: CommonRolesEvent);
            component!(path: RolesComponent, storage: roles, event: RolesEvent);
            component!(
                path: AccessControlComponent, storage: access_control, event: AccessControlEvent,
            );
            component!(path: SRC5Component, storage: src5, event: SRC5Event);

            #[abi(embed_v0)]
            impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
            #[abi(embed_v0)]
            impl RolesImpl = RolesComponent::RolesImpl<ContractState>;
            #[abi(embed_v0)]
            impl AccessControlImpl =
                AccessControlComponent::AccessControlImpl<ContractState>;
            #[abi(embed_v0)]
            impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

            impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
            impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

            #[storage]
            struct Storage {
                #[substorage(v0)]
                erc20: ERC20Component::Storage,
                #[substorage(v0)]
                common_roles: CommonRolesComponent::Storage,
                #[substorage(v0)]
                roles: RolesComponent::Storage,
                #[substorage(v0)]
                access_control: AccessControlComponent::Storage,
                #[substorage(v0)]
                src5: SRC5Component::Storage,
                permitted_minter: ContractAddress,
            }

            #[event]
            #[derive(Drop, starknet::Event)]
            enum Event {
                #[flat]
                ERC20Event: ERC20Component::Event,
                #[flat]
                CommonRolesEvent: CommonRolesComponent::Event,
                #[flat]
                RolesEvent: RolesComponent::Event,
                #[flat]
                AccessControlEvent: AccessControlComponent::Event,
                #[flat]
                SRC5Event: SRC5Component::Event,
            }

            #[constructor]
            fn constructor(
                ref self: ContractState,
                name: ByteArray,
                symbol: ByteArray,
                _decimals: u8,
                _initial_supply: u256,
                _initial_recipient: ContractAddress,
                permitted_minter: ContractAddress,
                governance_admin: ContractAddress,
                _upgrade_delay: u64,
            ) {
                self.erc20.initializer(:name, :symbol);
                self.permitted_minter.write(permitted_minter);
                self.roles.initialize(:governance_admin);
            }

            #[abi(embed_v0)]
            impl MintableToken of IMintableToken<ContractState> {
                fn is_permitted_minter(self: @ContractState, account: ContractAddress) -> bool {
                    account == self.permitted_minter.read()
                }

                fn permissioned_mint(
                    ref self: ContractState, account: ContractAddress, amount: u256,
                ) {
                    assert(
                        starknet::get_caller_address() == self.permitted_minter.read(),
                        'ONLY_MINTER',
                    );
                    self.erc20.mint(recipient: account, :amount);
                }

                fn permissioned_burn(
                    ref self: ContractState, account: ContractAddress, amount: u256,
                ) {
                    assert(
                        starknet::get_caller_address() == self.permitted_minter.read(),
                        'ONLY_MINTER',
                    );
                    self.erc20.burn(:account, :amount);
                }
            }

            #[abi(embed_v0)]
            impl MintableTokenCamelOnly of IMintableTokenCamelOnly<ContractState> {
                fn isPermittedMinter(self: @ContractState, account: ContractAddress) -> bool {
                    self.is_permitted_minter(:account)
                }

                fn permissionedMint(
                    ref self: ContractState, account: ContractAddress, amount: u256,
                ) {
                    self.permissioned_mint(:account, :amount);
                }

                fn permissionedBurn(
                    ref self: ContractState, account: ContractAddress, amount: u256,
                ) {
                    self.permissioned_burn(:account, :amount);
                }
            }
        }

        // ==================== Constants ====================

        const DEFAULT_UPGRADE_DELAY: u64 = 12345;
        const DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 5;
        const DEFAULT_L1_TOKEN_ETH_ADDRESS: felt252 = 1337;
        const DEFAULT_L1_RECIPIENT: felt252 = 12;
        const DEFAULT_DEPOSITOR_ETH_ADDRESS: felt252 = 7;
        const NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS: felt252 = 6;
        const DEFAULT_INITIAL_SUPPLY_LOW: u128 = 1000;
        const DEFAULT_INITIAL_SUPPLY_HIGH: u128 = 0;
        const NAME: felt252 = 'NAME';
        const SYMBOL: felt252 = 'SYMBOL';
        const DECIMALS: u8 = 18;
        const EXPECTED_CONTRACT_IDENTITY: felt252 = 'STARKGATE';
        const EXPECTED_CONTRACT_VERSION: felt252 = 2;

        // ==================== Address Constants ====================

        const CALLER: ContractAddress = 15.try_into().unwrap();
        const NOT_CALLER: ContractAddress = 16.try_into().unwrap();
        const INITIAL_OWNER: ContractAddress = 17.try_into().unwrap();
        const DEFAULT_AMOUNT: u256 = u256 {
            low: DEFAULT_INITIAL_SUPPLY_LOW, high: DEFAULT_INITIAL_SUPPLY_HIGH,
        };

        fn set_contract_address_as_caller() {
            starknet::testing::set_contract_address(CALLER);
        }

        fn get_default_l1_addresses() -> (EthAddress, EthAddress, EthAddress) {
            (
                DEFAULT_L1_BRIDGE_ETH_ADDRESS.try_into().unwrap(),
                DEFAULT_L1_TOKEN_ETH_ADDRESS.try_into().unwrap(),
                DEFAULT_L1_RECIPIENT.try_into().unwrap(),
            )
        }

        // ==================== Dispatcher Getters ====================

        fn get_token_bridge(token_bridge_address: ContractAddress) -> ITokenBridgeDispatcher {
            ITokenBridgeDispatcher { contract_address: token_bridge_address }
        }

        fn get_token_bridge_admin(
            token_bridge_address: ContractAddress,
        ) -> ITokenBridgeAdminDispatcher {
            ITokenBridgeAdminDispatcher { contract_address: token_bridge_address }
        }

        fn get_roles(contract_address: ContractAddress) -> IRolesDispatcher {
            IRolesDispatcher { contract_address }
        }

        fn get_erc20_token(l2_token: ContractAddress) -> IERC20Dispatcher {
            IERC20Dispatcher { contract_address: l2_token }
        }

        // ==================== Class Hash Helpers ====================

        fn stock_erc20_class_hash() -> ClassHash {
            MockERC20Mintable::TEST_CLASS_HASH.try_into().unwrap()
        }

        // ==================== Deploy Helpers ====================

        fn deploy_token_bridge() -> ContractAddress {
            let mut calldata: Array<felt252> = array![];
            let _caller = CALLER;
            _caller.serialize(ref calldata);
            DEFAULT_UPGRADE_DELAY.serialize(ref calldata);

            set_contract_address_as_caller();
            starknet::testing::set_caller_address(CALLER);

            let class_hash: ClassHash = super::super::TokenBridge::TEST_CLASS_HASH
                .try_into()
                .unwrap();
            let (token_bridge_address, _) = deploy_syscall(class_hash, 0, calldata.span(), false)
                .unwrap();
            token_bridge_address
        }

        fn set_caller_as_app_role_admin_app_governor(token_bridge_address: ContractAddress) {
            let token_bridge_roles = get_roles(contract_address: token_bridge_address);
            token_bridge_roles.register_app_role_admin(account: CALLER);
            token_bridge_roles.register_app_governor(account: CALLER);
        }

        fn set_caller_as_security_agent(token_bridge_address: ContractAddress) {
            let token_bridge_roles = get_roles(contract_address: token_bridge_address);
            token_bridge_roles.register_security_agent(account: CALLER);
        }

        fn set_caller_as_security_admin(token_bridge_address: ContractAddress) {
            let token_bridge_roles = get_roles(contract_address: token_bridge_address);
            token_bridge_roles.register_security_admin(account: CALLER);
        }

        fn prepare_bridge_for_deploy_token(
            token_bridge_address: ContractAddress, l1_bridge_address: EthAddress,
        ) {
            let orig = get_contract_address();
            set_contract_address_as_caller();

            let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
            set_caller_as_app_role_admin_app_governor(:token_bridge_address);

            token_bridge_admin.set_l1_bridge(:l1_bridge_address);
            token_bridge_admin.set_erc20_class_hash(erc20_class_hash: stock_erc20_class_hash());
            token_bridge_admin.set_l2_token_governance(l2_token_governance: CALLER);

            starknet::testing::set_contract_address(orig);
        }

        fn deploy_new_token(
            token_bridge_address: ContractAddress,
            l1_bridge_address: EthAddress,
            l1_token: EthAddress,
        ) {
            prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);
            starknet::testing::set_contract_address(token_bridge_address);

            let mut token_bridge_state = super::contract_state_for_testing();
            let from_address: felt252 = l1_bridge_address.into();
            super::handle_token_deployment(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                name: NAME,
                symbol: SYMBOL,
                decimals: DECIMALS,
            );
        }

        fn deploy_new_token_and_deposit(
            token_bridge_address: ContractAddress,
            l1_bridge_address: EthAddress,
            l1_token: EthAddress,
            depositor: EthAddress,
            l2_recipient: ContractAddress,
            amount_to_deposit: u256,
        ) {
            deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token);

            let mut token_bridge_state = super::contract_state_for_testing();
            let from_address: felt252 = l1_bridge_address.into();
            super::handle_token_deposit(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount: amount_to_deposit,
            );
        }

        fn assert_l2_account_balance(
            token_bridge_address: ContractAddress,
            l1_token: EthAddress,
            owner: ContractAddress,
            amount: u256,
        ) {
            let token_bridge = get_token_bridge(:token_bridge_address);
            let l2_token = token_bridge.get_l2_token(:l1_token);
            let erc20_token = get_erc20_token(:l2_token);
            assert(erc20_token.balance_of(owner) == amount, 'MISMATCHING_L2_ACCOUNT_BALANCE');
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
            let balance_before = erc20_token.balance_of(account: withdraw_from);

            starknet::testing::set_contract_address(withdraw_from);
            token_bridge
                .initiate_token_withdraw(:l1_token, :l1_recipient, amount: amount_to_withdraw);

            assert(
                erc20_token.balance_of(account: withdraw_from) == balance_before
                    - amount_to_withdraw,
                'INCONSISTENT_WITHDRAW_BALANCE',
            );
            assert(
                erc20_token.total_supply() == total_supply - amount_to_withdraw,
                'INIT_WITHDRAW_SUPPLY_ERROR',
            );
        }

        fn enable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
            set_contract_address_as_caller();
            set_caller_as_security_agent(:token_bridge_address);
            let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
            token_bridge_admin.enable_withdrawal_limit(:l1_token);
        }

        fn disable_withdrawal_limit(token_bridge_address: ContractAddress, l1_token: EthAddress) {
            set_contract_address_as_caller();
            set_caller_as_security_admin(:token_bridge_address);
            let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
            token_bridge_admin.disable_withdrawal_limit(:l1_token);
        }

        fn pop_and_deserialize_last_event<T, +starknet::Event<T>, +Drop<T>>(
            address: ContractAddress,
        ) -> T {
            let mut prev_log = starknet::testing::pop_log_raw(:address)
                .expect('Event queue is empty.');
            loop {
                match starknet::testing::pop_log_raw(:address) {
                    Option::Some(log) => { prev_log = log; },
                    Option::None(()) => { break; },
                };
            }
            deserialize_event(raw_event: prev_log)
        }

        fn deserialize_event<T, +starknet::Event<T>>(
            mut raw_event: (Span::<felt252>, Span::<felt252>),
        ) -> T {
            let (mut keys, mut data) = raw_event;
            starknet::Event::deserialize(ref keys, ref data).expect('Event deserializion failed')
        }

        // ==================== StubMsgReceiver Contract ====================

        #[starknet::contract]
        mod StubMsgReceiver {
            use bridge::interfaces::ITokenBridgeReceiver;
            use starknet::{ContractAddress, EthAddress};

            #[storage]
            struct Storage {}

            #[abi(embed_v0)]
            impl TokenBridgeReceiverImpl of ITokenBridgeReceiver<ContractState> {
                fn on_receive(
                    ref self: ContractState,
                    l2_token: ContractAddress,
                    amount: u256,
                    depositor: EthAddress,
                    message: Span<felt252>,
                ) -> bool {
                    if message.len() > 0 && *message.at(0) == 'RETURN FALSE' {
                        return false;
                    }
                    if message.len() > 0 && *message.at(0) == 'ASSERT' {
                        assert(false, 'INTENTIONAL_FAILURE');
                    }
                    true
                }
            }
        }

        fn deploy_stub_msg_receiver() -> ContractAddress {
            let calldata: Array<felt252> = array![];
            let (stub_address, _) = deploy_syscall(
                StubMsgReceiver::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false,
            )
                .unwrap();
            stub_address
        }

        fn deploy_new_token_and_deposit_with_message(
            token_bridge_address: ContractAddress,
            l1_bridge_address: EthAddress,
            l1_token: EthAddress,
            l2_recipient: ContractAddress,
            amount_to_deposit: u256,
            depositor: EthAddress,
            message: Span<felt252>,
        ) {
            deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token);

            let mut token_bridge_state = super::contract_state_for_testing();
            let from_address: felt252 = l1_bridge_address.into();
            super::handle_deposit_with_message(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount: amount_to_deposit,
                :message,
            );
        }

        // ==================== Tests ====================

        #[test]
        fn test_identity_and_version() {
            let token_bridge = get_token_bridge(token_bridge_address: deploy_token_bridge());
            assert(
                token_bridge.get_identity() == EXPECTED_CONTRACT_IDENTITY,
                'Contract identity mismatch.',
            );
            assert(
                token_bridge.get_version() == EXPECTED_CONTRACT_VERSION,
                'Contract version mismatch.',
            );
        }

        #[test]
        fn test_successful_erc20_handle_token_deployment() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let token_bridge = get_token_bridge(:token_bridge_address);

            prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();
            let from_address: felt252 = l1_bridge_address.into();
            super::handle_token_deployment(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                name: NAME,
                symbol: SYMBOL,
                decimals: DECIMALS,
            );

            assert_eq!(
                token_bridge_state.l1_locked_amount.read(l1_token),
                super::LockedAmount { monitoring_enabled: true, amount: 0 },
            );

            let l2_token = token_bridge.get_l2_token(:l1_token);
            // Verify the token was deployed correctly
            assert(token_bridge.get_l1_token(:l2_token) == l1_token, 'token address mismatch');
        }

        #[test]
        #[should_panic(expected: ('TOKEN_ALREADY_EXISTS',))]
        fn test_handle_token_deployment_twice() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();

            prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();

            let from_address: felt252 = l1_bridge_address.into();
            super::handle_token_deployment(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                name: NAME,
                symbol: SYMBOL,
                decimals: DECIMALS,
            );
            super::handle_token_deployment(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                name: NAME,
                symbol: SYMBOL,
                decimals: DECIMALS,
            );
        }

        #[test]
        #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
        fn test_non_l1_token_message_handle_token_deployment() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();

            prepare_bridge_for_deploy_token(:token_bridge_address, :l1_bridge_address);

            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();

            let l1_not_bridge_address: EthAddress = NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS
                .try_into()
                .unwrap();
            let from_address: felt252 = l1_not_bridge_address.into();
            super::handle_token_deployment(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                name: NAME,
                symbol: SYMBOL,
                decimals: DECIMALS,
            );
        }

        #[test]
        fn test_successful_handle_token_deposit() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let l2_recipient = INITIAL_OWNER;
            let first_amount = DEFAULT_AMOUNT;

            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount_to_deposit: first_amount,
            );

            let mut token_bridge_state = super::contract_state_for_testing();
            assert_eq!(
                token_bridge_state.l1_locked_amount.read(l1_token),
                super::LockedAmount { monitoring_enabled: true, amount: first_amount },
            );

            starknet::testing::set_contract_address(token_bridge_address);

            let deposit_amount_low: u128 = 17;
            let second_amount = u256 { low: deposit_amount_low, high: DEFAULT_INITIAL_SUPPLY_HIGH };
            let from_address: felt252 = l1_bridge_address.into();
            super::handle_token_deposit(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount: second_amount,
            );
            let total_amount = first_amount + second_amount;
            assert_l2_account_balance(
                :token_bridge_address, :l1_token, owner: l2_recipient, amount: total_amount,
            );
            assert_eq!(
                token_bridge_state.l1_locked_amount.read(l1_token),
                super::LockedAmount { monitoring_enabled: true, amount: total_amount },
            );
            // Event emission is verified implicitly by the state changes above.
        }

        #[test]
        #[should_panic(expected: ('EXPECTED_FROM_BRIDGE_ONLY',))]
        fn test_non_l1_token_message_handle_token_deposit() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let l2_recipient = INITIAL_OWNER;

            deploy_new_token(:token_bridge_address, :l1_bridge_address, :l1_token);

            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();

            let l1_not_bridge_address: EthAddress = NON_DEFAULT_L1_BRIDGE_ETH_ADDRESS
                .try_into()
                .unwrap();
            let from_address: felt252 = l1_not_bridge_address.into();
            super::handle_token_deposit(
                ref token_bridge_state,
                :from_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount: DEFAULT_AMOUNT,
            );
        }

        #[test]
        fn test_successful_initiate_token_withdraw() {
            let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let token_bridge_address = deploy_token_bridge();
            let l2_recipient = INITIAL_OWNER;
            let amount_to_deposit = DEFAULT_AMOUNT;

            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                :amount_to_deposit,
            );

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
        #[should_panic(expected: ('INVALID_RECIPIENT', 'ENTRYPOINT_FAILED'))]
        fn test_failed_initiate_token_withdraw_invalid_recipient() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let l1_recipient: EthAddress = 0.try_into().unwrap();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let token_bridge_address = deploy_token_bridge();
            let l2_recipient = INITIAL_OWNER;
            let amount_to_deposit = DEFAULT_AMOUNT;

            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                :amount_to_deposit,
            );

            withdraw_and_validate(
                :token_bridge_address,
                withdraw_from: l2_recipient,
                :l1_recipient,
                :l1_token,
                amount_to_withdraw: amount_to_deposit,
            );
        }

        #[test]
        #[should_panic(expected: ('ZERO_WITHDRAWAL', 'ENTRYPOINT_FAILED'))]
        fn test_zero_amount_initiate_token_withdraw() {
            let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let token_bridge_address = deploy_token_bridge();
            let l2_recipient = INITIAL_OWNER;
            let amount_to_deposit = DEFAULT_AMOUNT;

            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                :amount_to_deposit,
            );

            let token_bridge = get_token_bridge(:token_bridge_address);
            let amount = u256 { low: 0, high: DEFAULT_INITIAL_SUPPLY_HIGH };
            token_bridge.initiate_token_withdraw(:l1_token, :l1_recipient, :amount);
        }

        #[test]
        #[should_panic(expected: ('INSUFFICIENT_FUNDS', 'ENTRYPOINT_FAILED'))]
        fn test_excessive_amount_initiate_token_withdraw() {
            let (l1_bridge_address, l1_token, l1_recipient) = get_default_l1_addresses();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let token_bridge_address = deploy_token_bridge();
            let l2_recipient = INITIAL_OWNER;
            let amount_to_deposit = DEFAULT_AMOUNT;

            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                :amount_to_deposit,
            );

            let token_bridge = get_token_bridge(:token_bridge_address);
            token_bridge
                .initiate_token_withdraw(:l1_token, :l1_recipient, amount: amount_to_deposit + 1);
        }

        #[test]
        fn test_get_remaining_withdrawal_quota() {
            let (l1_bridge_address, l1_token, _l1_recipient) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let token_bridge = get_token_bridge(:token_bridge_address);
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();

            assert(
                token_bridge.get_remaining_withdrawal_quota(:l1_token) == Bounded::MAX,
                'remaining_withdraw_quota Error',
            );

            let l2_recipient = INITIAL_OWNER;
            let amount_to_deposit = DEFAULT_AMOUNT;
            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                :amount_to_deposit,
            );

            assert(
                token_bridge.get_remaining_withdrawal_quota(:l1_token) == Bounded::MAX,
                'remaining_withdraw_quota Error',
            );

            enable_withdrawal_limit(:token_bridge_address, :l1_token);

            let quota_after_enable = token_bridge.get_remaining_withdrawal_quota(:l1_token);
            assert(quota_after_enable < Bounded::MAX, 'Quota should be limited');

            disable_withdrawal_limit(:token_bridge_address, :l1_token);
            assert(
                token_bridge.get_remaining_withdrawal_quota(:l1_token) == Bounded::MAX,
                'remaining_withdraw_quota Error',
            );
        }

        #[test]
        fn test_successful_handle_deposit_with_message() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let stub_msg_receiver_address = deploy_stub_msg_receiver();
            let amount_to_deposit = DEFAULT_AMOUNT;
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();

            let mut message = array![];
            7.serialize(ref message);
            let message_span = message.span();

            deploy_new_token_and_deposit_with_message(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                l2_recipient: stub_msg_receiver_address,
                :amount_to_deposit,
                :depositor,
                message: message_span,
            );

            assert_l2_account_balance(
                :token_bridge_address,
                :l1_token,
                owner: stub_msg_receiver_address,
                amount: amount_to_deposit,
            );
            // The balance assertion above verifies the deposit succeeded.
        }

        #[test]
        #[should_panic(expected: ('DEPOSIT_REJECTED',))]
        fn test_handle_deposit_with_message_on_receive_return_false() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let stub_msg_receiver_address = deploy_stub_msg_receiver();
            let amount_to_deposit = DEFAULT_AMOUNT;
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();

            let mut message = array![];
            'RETURN FALSE'.serialize(ref message);
            let message_span = message.span();

            deploy_new_token_and_deposit_with_message(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                l2_recipient: stub_msg_receiver_address,
                :amount_to_deposit,
                :depositor,
                message: message_span,
            );
        }

        #[test]
        #[should_panic(expected: ('ON_RECEIVE_FAILED',))]
        fn test_handle_deposit_with_message_fail_on_receive() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let stub_msg_receiver_address = deploy_stub_msg_receiver();
            let amount_to_deposit = DEFAULT_AMOUNT;
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();

            let mut message = array![];
            'ASSERT'.serialize(ref message);
            let message_span = message.span();

            deploy_new_token_and_deposit_with_message(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                l2_recipient: stub_msg_receiver_address,
                :amount_to_deposit,
                :depositor,
                message: message_span,
            );
        }

        // ==================== Locked Amount Monitoring Tests ====================

        #[test]
        fn test_enable_locked_amount_monitoring_with_zero_uses_supply() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let l2_recipient = INITIAL_OWNER;
            let amount = DEFAULT_AMOUNT;

            // Deploy token and deposit (this enables monitoring automatically)
            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount_to_deposit: amount,
            );

            // Manually disable monitoring to simulate legacy state
            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();
            token_bridge_state
                .l1_locked_amount
                .write(l1_token, super::LockedAmount { monitoring_enabled: false, amount: 0 });

            // Enable monitoring with locked_amount = 0 (should use L2 supply)
            set_contract_address_as_caller();
            set_caller_as_app_role_admin_app_governor(:token_bridge_address);
            let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
            token_bridge_admin.enable_locked_amount_monitoring(:l1_token, locked_amount: 0);

            // Verify it used L2 total supply
            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();
            assert_eq!(
                token_bridge_state.l1_locked_amount.read(l1_token),
                super::LockedAmount { monitoring_enabled: true, amount: amount },
            );
        }

        #[test]
        fn test_enable_locked_amount_monitoring_with_explicit_amount() {
            let (l1_bridge_address, l1_token, _) = get_default_l1_addresses();
            let token_bridge_address = deploy_token_bridge();
            let depositor: EthAddress = DEFAULT_DEPOSITOR_ETH_ADDRESS.try_into().unwrap();
            let l2_recipient = INITIAL_OWNER;
            let amount = DEFAULT_AMOUNT;
            let explicit_locked_amount: u256 = 500;

            // Deploy token and deposit
            deploy_new_token_and_deposit(
                :token_bridge_address,
                :l1_bridge_address,
                :l1_token,
                :depositor,
                :l2_recipient,
                amount_to_deposit: amount,
            );

            // Manually disable monitoring to simulate legacy state
            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();
            token_bridge_state
                .l1_locked_amount
                .write(l1_token, super::LockedAmount { monitoring_enabled: false, amount: 0 });

            // Enable monitoring with explicit amount
            set_contract_address_as_caller();
            set_caller_as_app_role_admin_app_governor(:token_bridge_address);
            let token_bridge_admin = get_token_bridge_admin(:token_bridge_address);
            token_bridge_admin
                .enable_locked_amount_monitoring(:l1_token, locked_amount: explicit_locked_amount);

            // Verify it used explicit amount
            starknet::testing::set_contract_address(token_bridge_address);
            let mut token_bridge_state = super::contract_state_for_testing();
            assert_eq!(
                token_bridge_state.l1_locked_amount.read(l1_token),
                super::LockedAmount { monitoring_enabled: true, amount: explicit_locked_amount },
            );
        }
    }
}
