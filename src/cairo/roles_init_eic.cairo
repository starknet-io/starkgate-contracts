// An External Initializer Contract to initialize roles in a middle of an upgrade.
// This contract is needed when upgrading to a class hash that relies on Roles been initialized,
// from a class hash that doesn't support Roles.
// In normal conditions, Roles are initialized in constructor, i.e. during deployment.
// This contract initializes Roles, post deployment, as an the upgrade eic.
#[starknet::contract]
mod RolesExternalInitializer {
    use starknet::{
        ContractAddress, get_caller_address, //EthAddress, EthAddressIntoFelt252, EthAddressSerde
    };
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
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 0, 'NO_EIC_INIT_DATA_EXPECTED');
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
    }
}

