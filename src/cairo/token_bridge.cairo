use starknet::ContractAddress;
use serde::Serde;
use traits::Into;
use zeroable::Zeroable;

const DEFAULT_ADMIN_ROLE: felt252 = 0;


#[starknet::contract]
mod TokenBridge {
    use array::ArrayTrait;
    use integer::{Felt252IntoU256, U64IntoFelt252};
    use option::OptionTrait;
    use serde::Serde;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ContractAddress, get_caller_address, EthAddress, EthAddressIntoFelt252, EthAddressSerde,
        EthAddressZeroable, syscalls::send_message_to_l1_syscall, get_block_timestamp,
        replace_class_syscall
    };
    use starknet::class_hash::{ClassHash, Felt252TryIntoClassHash};
    use super::super::token_bridge_interface::{
        ITokenBridge, ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait
    };
    use super::super::access_control_interface::IAccessControl;
    use super::super::roles_interface::IRoles;
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::DEFAULT_ADMIN_ROLE;


    use super::super::replaceability_interface::{
        ImplementationData, IReplaceable, IReplaceableDispatcher, IReplaceableDispatcherTrait
    };

    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    const WITHDRAW_MESSAGE: felt252 = 0;
    const CONTRACT_IDENTITY: felt252 = 'STARKGATE';
    const CONTRACT_VERSION: felt252 = 2;


    // int.from_bytes(Web3.keccak(text="ROLE_APP_GOVERNOR"), "big") & MASK_250 .
    const APP_GOVERNOR: felt252 = 0xd2ead78c620e94b02d0a996e99298c59ddccfa1d8a0149080ac3a20de06068;

    // int.from_bytes(Web3.keccak(text="ROLE_APP_ROLE_ADMIN"), "big") & MASK_250 .
    const APP_ROLE_ADMIN: felt252 =
        0x3e615638e0b79444a70f8c695bf8f2a47033bf1cf95691ec3130f64939cee99;

    // int.from_bytes(Web3.keccak(text="ROLE_GOVERNANCE_ADMIN"), "big") & MASK_250 .
    const GOVERNANCE_ADMIN: felt252 =
        0x3711c9d994faf6055172091cb841fd4831aa743e6f3315163b06a122c841846;

    // int.from_bytes(Web3.keccak(text="ROLE_OPERATOR"), "big") & MASK_250 .
    const OPERATOR: felt252 = 0x023edb77f7c8cc9e38e8afe78954f703aeeda7fffe014eeb6e56ea84e62f6da7;

    // int.from_bytes(Web3.keccak(text="ROLE_TOKEN_ADMIN"), "big") & MASK_250 .
    const TOKEN_ADMIN: felt252 = 0x0128d63adbf6b09002c26caf55c47e2f26635807e3ef1b027218aa74c8d61a3e;

    // int.from_bytes(Web3.keccak(text="ROLE_UPGRADE_GOVERNOR"), "big") & MASK_250 .
    const UPGRADE_GOVERNOR: felt252 =
        0x251e864ca2a080f55bce5da2452e8cfcafdbc951a3e7fff5023d558452ec228;

    #[storage]
    struct Storage {
        // --- Token Bridge ---
        // The L1 bridge address. Zero when unset.
        l1_bridge: EthAddress,
        // The L2 token contract address. Zero when unset.
        l2_token: ContractAddress,
        // --- Replaceability ---
        // Delay in seconds before performing an upgrade.
        upgrade_delay: u64,
        // Timestamp by which implementation can be activated.
        impl_activation_time: LegacyMap<felt252, u64>,
        // Is the implementation finalized.
        finalized: bool,
        // --- Access Control ---
        // For each role id store its role admin id.
        role_admin: LegacyMap<felt252, felt252>,
        // For each address and role, stores true if the address has this role; otherwise, false.
        role_members: LegacyMap<(felt252, ContractAddress), bool>,
        // --- Roles ---
        roles_initialized: bool,
    }

    #[event]
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    enum Event {
        // --- Token Bridge ---
        #[event]
        L1BridgeSet: L1BridgeSet,
        #[event]
        L2TokenSet: L2TokenSet,
        #[event]
        WithdrawInitiated: WithdrawInitiated,
        #[event]
        DepositHandled: DepositHandled,
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
        AppGovernorAdded: AppGovernorAdded,
        #[event]
        AppGovernorRemoved: AppGovernorRemoved,
        #[event]
        AppRoleAdminAdded: AppRoleAdminAdded,
        #[event]
        AppRoleAdminRemoved: AppRoleAdminRemoved,
        #[event]
        GovernanceAdminAdded: GovernanceAdminAdded,
        #[event]
        GovernanceAdminRemoved: GovernanceAdminRemoved,
        #[event]
        OperatorAdded: OperatorAdded,
        #[event]
        OperatorRemoved: OperatorRemoved,
        #[event]
        TokenAdminAdded: TokenAdminAdded,
        #[event]
        TokenAdminRemoved: TokenAdminRemoved,
        #[event]
        UpgradeGovernorAdded: UpgradeGovernorAdded,
        #[event]
        UpgradeGovernorRemoved: UpgradeGovernorRemoved,
    }

    // An event that is emitted when set_l1_bridge is called.
    // * l1_bridge_address is the new l1 bridge address.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct L1BridgeSet {
        l1_bridge_address: EthAddress, 
    }

    // An event that is emitted when set_l2_token is called.
    // * l2_token_address is the new l2 token address.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct L2TokenSet {
        l2_token_address: ContractAddress, 
    }

    // An event that is emitted when initiate_withdraw is called.
    // * l1_recipient is the l1 recipient address.
    // * amount is the amount to withdraw.
    // * caller_address is the address from which the call was made.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct WithdrawInitiated {
        l1_recipient: EthAddress,
        amount: u256,
        caller_address: ContractAddress,
    }

    // An event that is emitted when handle_deposit is called.
    // * account is the recipient address.
    // * amount is the amount to deposit.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct DepositHandled {
        account: ContractAddress,
        amount: u256,
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
        role: felt252,
        account: ContractAddress,
        sender: ContractAddress,
    }

    // An event that is emitted when `account` is revoked `role`.
    // `sender` is the account that originated the contract call:
    //   - If using `revoke_role`, it is the admin role bearer.
    //   - If using `renounce_role`, it is the role bearer (i.e. `account`).
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct RoleRevoked {
        role: felt252,
        account: ContractAddress,
        sender: ContractAddress,
    }

    // An event that is emitted when `new_admin_role` is set as `role`'s admin role, replacing
    // `previous_admin_role`.
    // `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite {RoleAdminChanged} not
    // being emitted signaling this.
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct RoleAdminChanged {
        role: felt252,
        previous_admin_role: felt252,
        new_admin_role: felt252,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct AppGovernorAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct AppGovernorRemoved {
        removed_account: ContractAddress,
        removed_by: ContractAddress,
    }
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct AppRoleAdminAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct AppRoleAdminRemoved {
        removed_account: ContractAddress,
        removed_by: ContractAddress,
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
    struct OperatorAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct OperatorRemoved {
        removed_account: ContractAddress,
        removed_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct TokenAdminAdded {
        added_account: ContractAddress,
        added_by: ContractAddress,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    struct TokenAdminRemoved {
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

    #[constructor]
    fn constructor(ref self: ContractState, upgrade_delay: u64) {
        self._initialize_roles(provisional_governance_admin: get_caller_address());
        self.upgrade_delay.write(upgrade_delay);
    }

    #[generate_trait]
    impl InternalFunctions of IInternalFunctions {
        // --- Token Bridge ---
        // Read l1_bridge and verify it's initialized.
        fn get_l1_bridge_address(self: @ContractState) -> EthAddress {
            let l1_bridge_address = self.l1_bridge.read();
            assert(l1_bridge_address.is_non_zero(), 'UNINITIALIZED_L1_BRIDGE_ADDRESS');
            l1_bridge_address
        }

        // Read l2_token and verify it's initialized.
        fn get_l2_token_address(self: @ContractState) -> ContractAddress {
            let l2_token_address = self.l2_token.read();
            assert(l2_token_address.is_non_zero(), 'UNINITIALIZED_L2_TOKEN');
            l2_token_address
        }

        // --- Replaceability ---

        fn finalize(ref self: ContractState) {
            self.finalized.write(true);
        }


        // --- Access Control ---
        fn assert_only_role(self: @ContractState, role: felt252) {
            let authorized: bool = self.has_role(:role, account: get_caller_address());
            assert(authorized, 'Caller is missing role');
        }

        //
        // WARNING
        // The following internal methods are unprotected and should not be used
        // outside of a contract's constructor.
        //

        fn _grant_role(ref self: ContractState, role: felt252, account: ContractAddress) {
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

        fn _revoke_role(ref self: ContractState, role: felt252, account: ContractAddress) {
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

        fn _set_role_admin(ref self: ContractState, role: felt252, admin_role: felt252) {
            let previous_admin_role: felt252 = self.get_role_admin(:role);
            self.role_admin.write(role, admin_role);
            self
                .emit(
                    Event::RoleAdminChanged(
                        RoleAdminChanged { role, previous_admin_role, new_admin_role: admin_role }
                    )
                );
        }
        // --- Roles ---
        // TODO -  change the fn name to _grant_role when we can have modularity.
        fn _grant_role_and_emit(
            ref self: ContractState, role: felt252, account: ContractAddress, event: Event
        ) {
            if !self.has_role(:role, :account) {
                assert(account.is_non_zero(), 'INVALID_ACCOUNT_ADDRESS');
                self.grant_role(:role, :account);
                self.emit(event);
            }
        }

        // TODO -  change the fn name to _revoke_role when we can have modularity.
        fn _revoke_role_and_emit(
            ref self: ContractState, role: felt252, account: ContractAddress, event: Event
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
        // TODO -  This function should be under initialize function under roles contract.

        // Role                |   Role Admin
        // ----------------------------------------
        // GOVERNANCE_ADMIN    |   GOVERNANCE_ADMIN
        // UPGRADE_GOVERNOR    |   GOVERNANCE_ADMIN
        // APP_ROLE_ADMIN      |   GOVERNANCE_ADMIN
        // APP_GOVERNOR        |   APP_ROLE_ADMIN
        // OPERATOR            |   APP_ROLE_ADMIN
        // TOKEN_ADMIN         |   APP_ROLE_ADMIN.
        fn _initialize_roles(
            ref self: ContractState, provisional_governance_admin: ContractAddress
        ) {
            let is_initialized = self.roles_initialized.read();
            assert(!is_initialized, 'ROLES_ALREADY_INITIALIZED');
            assert(provisional_governance_admin.is_non_zero(), 'ZERO_PROVISIONAL_GOV_ADMIN');
            self.roles_initialized.write(true);
            self._grant_role(role: GOVERNANCE_ADMIN, account: provisional_governance_admin);
            self._set_role_admin(role: APP_GOVERNOR, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: APP_ROLE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: GOVERNANCE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: OPERATOR, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: TOKEN_ADMIN, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: UPGRADE_GOVERNOR, admin_role: GOVERNANCE_ADMIN);
        }

        fn only_app_governor(self: @ContractState) {
            assert(self.is_app_governor(get_caller_address()), 'ONLY_APP_GOVERNOR');
        }
        fn only_app_role_admin(self: @ContractState) {
            assert(self.is_app_role_admin(get_caller_address()), 'ONLY_APP_ROLE_ADMIN');
        }
        fn only_governance_admin(self: @ContractState) {
            assert(self.is_governance_admin(get_caller_address()), 'ONLY_GOVERNANCE_ADMIN');
        }
        fn only_operator(self: @ContractState) {
            assert(self.is_operator(get_caller_address()), 'ONLY_OPERATOR');
        }
        fn only_token_admin(self: @ContractState) {
            assert(self.is_token_admin(get_caller_address()), 'ONLY_TOKEN_ADMIN');
        }
        fn only_upgrade_governor(self: @ContractState) {
            assert(self.is_upgrade_governor(get_caller_address()), 'ONLY_UPGRADE_GOVERNOR');
        }
    }


    #[external(v0)]
    impl TokenBridge of ITokenBridge<ContractState> {
        fn get_version(self: @ContractState) -> felt252 {
            CONTRACT_VERSION
        }

        fn get_identity(self: @ContractState) -> felt252 {
            CONTRACT_IDENTITY
        }

        fn set_l1_bridge(ref self: ContractState, l1_bridge_address: EthAddress) {
            // The call is restricted to the app governor.
            self.only_app_governor();
            assert(self.l1_bridge.read().is_zero(), 'L1_BRIDGE_ALREADY_INITIALIZED');
            assert(l1_bridge_address.is_non_zero(), 'ZERO_L1_BRIDGE_ADDRESS');
            self.l1_bridge.write(l1_bridge_address.into());
            self.emit(Event::L1BridgeSet(L1BridgeSet { l1_bridge_address }));
        }


        fn set_l2_token(ref self: ContractState, l2_token_address: ContractAddress) {
            // The call is restricted to the app governor.
            self.only_app_governor();
            assert(self.l2_token.read().is_zero(), 'L2_TOKEN_ALREADY_INITIALIZED');
            assert(l2_token_address.is_non_zero(), 'ZERO_L2_TOKEN_ADDRESS');
            self.l2_token.write(l2_token_address);
            self.emit(Event::L2TokenSet(L2TokenSet { l2_token_address }));
        }


        fn initiate_withdraw(ref self: ContractState, l1_recipient: EthAddress, amount: u256) {
            // Read addresses.
            let caller_address = get_caller_address();
            let l2_token_address = self.get_l2_token_address();
            let l1_bridge_address = self.get_l1_bridge_address();

            // Validate amount.
            assert(amount != u256 { low: 0, high: 0 }, 'ZERO_WITHDRAWAL');
            let caller_balance = IERC20Dispatcher {
                contract_address: l2_token_address
            }.balance_of(account: caller_address);
            assert(amount <= caller_balance, 'INSUFFICIENT_FUNDS');

            // Call burn on l2_token contract.
            IMintableTokenDispatcher {
                contract_address: l2_token_address
            }.permissioned_burn(account: caller_address, :amount);

            // Send the message.
            let mut message_payload = ArrayTrait::new();
            WITHDRAW_MESSAGE.serialize(ref message_payload);
            l1_recipient.serialize(ref message_payload);
            amount.serialize(ref message_payload);

            send_message_to_l1_syscall(
                to_address: l1_bridge_address.into(), payload: message_payload.span()
            );
            self
                .emit(
                    Event::WithdrawInitiated(
                        WithdrawInitiated { l1_recipient, amount, caller_address }
                    )
                );
        }
    }

    // -- Replaceability --

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

        fn get_impl_activation_time(
            self: @ContractState, implementation_data: ImplementationData
        ) -> u64 {
            let impl_key = calc_impl_key(:implementation_data);
            self.impl_activation_time.read(impl_key)
        }

        fn add_new_implementation(
            ref self: ContractState, implementation_data: ImplementationData
        ) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            let now = get_block_timestamp();
            let upgrade_timelock = self.upgrade_delay.read();
            let impl_key = calc_impl_key(:implementation_data);

            // TODO -  add an assertion that the `implementation_data.impl_hash` is declared.

            self.impl_activation_time.write(impl_key, now + upgrade_timelock);

            self
                .emit(
                    Event::ImplementationAdded(
                        ImplementationAdded { implementation_data: implementation_data }
                    )
                );
        }
        fn remove_implementation(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Read implementation activation time.
            let impl_key = calc_impl_key(:implementation_data);
            let impl_activation_time = self.impl_activation_time.read(impl_key);

            if (impl_activation_time.is_non_zero()) {
                self.impl_activation_time.write(impl_key, 0);
                self
                    .emit(
                        Event::ImplementationRemoved(
                            ImplementationRemoved { implementation_data: implementation_data }
                        )
                    );
            }
        }
        fn replace_to(ref self: ContractState, implementation_data: ImplementationData) {
            // The call is restricted to the upgrade governor.
            self.only_upgrade_governor();

            // Validate implementation is not finalized.
            assert(false == self.finalized.read(), 'FINALIZED');

            let now = get_block_timestamp();
            let impl_key = calc_impl_key(:implementation_data);
            let impl_activation_time = self.impl_activation_time.read(impl_key);

            // Zero activation time means that this implementation & init vector combination
            // was not previously added.
            assert(impl_activation_time.is_non_zero(), 'UNKNOWN_IMPLEMENTATION');

            assert(impl_activation_time <= now, 'NOT_ENABLED_YET');

            // We emit now so that finalize emits last (if it does).
            self
                .emit(
                    Event::ImplementationReplaced(
                        ImplementationReplaced { implementation_data: implementation_data }
                    )
                );

            // Finalize imeplementation, if needed.
            if (implementation_data.final == true) {
                self.finalize();
                self
                    .emit(
                        Event::ImplementationFinalized(
                            ImplementationFinalized { impl_hash: implementation_data.impl_hash }
                        )
                    );
            }
            // TODO handle eic.

            // Replace the class hash.
            starknet::replace_class_syscall(implementation_data.impl_hash);
        }
    }

    #[external(v0)]
    impl AccessControlImpl of IAccessControl<ContractState> {
        fn has_role(self: @ContractState, role: felt252, account: ContractAddress) -> bool {
            self.role_members.read((role, account))
        }

        fn get_role_admin(self: @ContractState, role: felt252) -> felt252 {
            self.role_admin.read(role)
        }

        fn grant_role(ref self: ContractState, role: felt252, account: ContractAddress) {
            let admin = self.get_role_admin(:role);
            self.assert_only_role(role: admin);
            self._grant_role(:role, :account);
        }

        fn revoke_role(ref self: ContractState, role: felt252, account: ContractAddress) {
            let admin: felt252 = self.get_role_admin(:role);
            self.assert_only_role(role: admin);
            self._revoke_role(:role, :account);
        }

        fn renounce_role(ref self: ContractState, role: felt252, account: ContractAddress) {
            assert(get_caller_address() == account, 'Can only renounce role for self');
            self._revoke_role(:role, :account);
        }
    }


    #[external(v0)]
    impl RolesImpl of IRoles<ContractState> {
        fn is_app_governor(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: APP_GOVERNOR, :account)
        }

        fn is_app_role_admin(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: APP_ROLE_ADMIN, :account)
        }

        fn is_governance_admin(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: GOVERNANCE_ADMIN, :account)
        }

        fn is_operator(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: OPERATOR, :account)
        }

        fn is_token_admin(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: TOKEN_ADMIN, :account)
        }

        fn is_upgrade_governor(self: @ContractState, account: ContractAddress) -> bool {
            self.has_role(role: UPGRADE_GOVERNOR, :account)
        }

        fn register_app_governor(ref self: ContractState, account: ContractAddress) {
            let event = Event::AppGovernorAdded(
                AppGovernorAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: APP_GOVERNOR, :account, :event);
        }

        fn remove_app_governor(ref self: ContractState, account: ContractAddress) {
            let event = Event::AppGovernorRemoved(
                AppGovernorRemoved { removed_account: account, removed_by: get_caller_address() }
            );
            self._revoke_role_and_emit(role: APP_GOVERNOR, :account, :event);
        }

        fn register_app_role_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::AppRoleAdminAdded(
                AppRoleAdminAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: APP_ROLE_ADMIN, :account, :event);
        }

        fn remove_app_role_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::AppRoleAdminRemoved(
                AppRoleAdminRemoved { removed_account: account, removed_by: get_caller_address() }
            );
            self._revoke_role_and_emit(role: APP_ROLE_ADMIN, :account, :event);
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

        fn register_operator(ref self: ContractState, account: ContractAddress) {
            let event = Event::OperatorAdded(
                OperatorAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: OPERATOR, :account, :event);
        }

        fn remove_operator(ref self: ContractState, account: ContractAddress) {
            let event = Event::OperatorRemoved(
                OperatorRemoved { removed_account: account, removed_by: get_caller_address() }
            );
            self._revoke_role_and_emit(role: OPERATOR, :account, :event);
        }

        fn register_token_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::TokenAdminAdded(
                TokenAdminAdded { added_account: account, added_by: get_caller_address() }
            );
            self._grant_role_and_emit(role: TOKEN_ADMIN, :account, :event);
        }

        fn remove_token_admin(ref self: ContractState, account: ContractAddress) {
            let event = Event::TokenAdminRemoved(
                TokenAdminRemoved { removed_account: account, removed_by: get_caller_address() }
            );
            self._revoke_role_and_emit(role: TOKEN_ADMIN, :account, :event);
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

        // TODO -  change the fn name to renounce_role when we can have modularity.
        // TODO -  change to GOVERNANCE_ADMIN_CANNOT_SELF_REMOVE when the 32 characters limitations
        // is off.
        fn renounce(ref self: ContractState, role: felt252) {
            assert(role != GOVERNANCE_ADMIN, 'GOV_ADMIN_CANNOT_SELF_REMOVE');
            self.renounce_role(:role, account: get_caller_address())
        // TODO add another event? Currently there are two events when a role is removed but
        // only one if it was renounced.
        }
    }

    #[l1_handler]
    fn handle_deposit(
        ref self: ContractState, from_address: felt252, account: ContractAddress, amount: u256
    ) {
        // Read addresses.
        let l2_token_address = self.get_l2_token_address();
        let l1_bridge_address = self.get_l1_bridge_address();

        // Verify deposit originating from the l1 bridge.
        assert(from_address == l1_bridge_address.into(), 'EXPECTED_FROM_BRIDGE_ONLY');

        // Call mint on l2_token contract.
        IMintableTokenDispatcher {
            contract_address: l2_token_address
        }.permissioned_mint(:account, :amount);

        self.emit(Event::DepositHandled(DepositHandled { account, amount }));
    }
}
