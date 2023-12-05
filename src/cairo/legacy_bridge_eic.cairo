// An EIC contract to upgrade a Starkgate legacy l2 bridge.
#[starknet::contract]
mod LegacyBridgeUpgradeEIC {
    const WITHDRAWAL_LIMIT_PCT: u8 = 5;
    use starknet::{
        ContractAddress, get_caller_address, EthAddress, EthAddressIntoFelt252, EthAddressSerde
    };
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::access_control_interface::{
        IAccessControl, RoleId, RoleAdminChanged, RoleGranted
    };
    use super::super::replaceability_interface::IEICInitializable;
    use super::super::roles_interface::{
        APP_GOVERNOR, APP_ROLE_ADMIN, GOVERNANCE_ADMIN, OPERATOR, SECURITY_ADMIN, SECURITY_AGENT,
        TOKEN_ADMIN, UPGRADE_GOVERNOR
    };

    #[storage]
    struct Storage {
        // --- Token Bridge ---
        // Mapping from between l1<->l2 token addresses.
        l1_l2_token_map: LegacyMap<EthAddress, ContractAddress>,
        l2_l1_token_map: LegacyMap<ContractAddress, EthAddress>,
        daily_withdrawal_limit_pct: u8,
        // `l2_token` is a legacy storage variable from older versions.
        // It's expected to be non-empty only in a case of an upgrade from such a version.
        //  This case also implies that this is the only token that is served by the bridge.
        l2_token: ContractAddress,
        // --- Access Control ---
        // For each role id store its role admin id.
        role_admin: LegacyMap<RoleId, RoleId>,
        // For each role and address, stores true if the address has this role; otherwise, false.
        role_members: LegacyMap<(RoleId, ContractAddress), bool>,
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    #[event]
    enum Event {
        // --- Access Control ---
        RoleGranted: RoleGranted,
        RoleAdminChanged: RoleAdminChanged,
    }

    #[external(v0)]
    impl EICInitializable of IEICInitializable<ContractState> {
        // Sets up the values needed in the legacy l2 bridge upgrade:
        // 1. Roles (governance) setup
        // 2. Populates L1-L2 token mapping.
        // 3. Initializes the withdrawal limit settings.
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 2, 'EIC_INIT_DATA_LEN_MISMATCH_2');
            self.daily_withdrawal_limit_pct.write(WITHDRAWAL_LIMIT_PCT);
            let l1_token: EthAddress = (*eic_init_data[0]).try_into().unwrap();
            let l2_token: ContractAddress = (*eic_init_data[1]).try_into().unwrap();
            self.setup_l1_l2_mappings(:l1_token, :l2_token);
            self._initialize_roles();
        }
    }

    #[generate_trait]
    impl internals of _internals {
        fn _initialize_roles(ref self: ContractState) {
            let provisional_governance_admin = get_caller_address();
            let un_initialized = self.get_role_admin(role: GOVERNANCE_ADMIN) == 0;
            assert(un_initialized, 'ROLES_ALREADY_INITIALIZED');
            self._grant_role(role: GOVERNANCE_ADMIN, account: provisional_governance_admin);
            self._grant_role(role: UPGRADE_GOVERNOR, account: provisional_governance_admin);
            self._set_role_admin(role: APP_GOVERNOR, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: APP_ROLE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: GOVERNANCE_ADMIN, admin_role: GOVERNANCE_ADMIN);
            self._set_role_admin(role: OPERATOR, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: TOKEN_ADMIN, admin_role: APP_ROLE_ADMIN);
            self._set_role_admin(role: UPGRADE_GOVERNOR, admin_role: GOVERNANCE_ADMIN);

            self._grant_role(role: SECURITY_ADMIN, account: provisional_governance_admin);
            self._set_role_admin(role: SECURITY_ADMIN, admin_role: SECURITY_ADMIN);
            self._set_role_admin(role: SECURITY_AGENT, admin_role: SECURITY_ADMIN);
        }

        fn _grant_role(ref self: ContractState, role: RoleId, account: ContractAddress) {
            if !self.has_role(:role, :account) {
                self.role_members.write((role, account), true);
                self.emit(RoleGranted { role, account, sender: get_caller_address() });
            }
        }

        fn _set_role_admin(ref self: ContractState, role: RoleId, admin_role: RoleId) {
            let previous_admin_role = self.get_role_admin(:role);
            self.role_admin.write(role, admin_role);
            self.emit(RoleAdminChanged { role, previous_admin_role, new_admin_role: admin_role });
        }

        fn get_role_admin(self: @ContractState, role: RoleId) -> RoleId {
            self.role_admin.read(role)
        }

        fn has_role(self: @ContractState, role: RoleId, account: ContractAddress) -> bool {
            self.role_members.read((role, account))
        }

        fn setup_l1_l2_mappings(
            ref self: ContractState, l1_token: EthAddress, l2_token: ContractAddress
        ) {
            // Check that running on legacy bridge context.
            let legacy_l2_token = self.l2_token.read();
            assert(legacy_l2_token.is_non_zero(), 'NOT_LEGACY_BRIDGE');

            assert(l1_token.is_non_zero(), 'ZERO_L1_TOKEN');
            assert(l2_token.is_non_zero(), 'ZERO_L2_TOKEN');

            assert(legacy_l2_token == l2_token, 'TOKEN_ADDRESS_MISMATCH');

            // Implicitly assert that the L2 token supports snake case (i.e. already upgraded.)
            IERC20Dispatcher { contract_address: l2_token }.total_supply();

            assert(self.l1_l2_token_map.read(l1_token).is_zero(), 'L2_BRIDGE_ALREADY_INITIALIZED');
            assert(self.l2_l1_token_map.read(l2_token).is_zero(), 'L2_BRIDGE_ALREADY_INITIALIZED');

            self.l1_l2_token_map.write(l1_token, l2_token);
            self.l2_l1_token_map.write(l2_token, l1_token);
        }
    }
}

