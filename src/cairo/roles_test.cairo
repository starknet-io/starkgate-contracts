#[cfg(test)]
mod roles_test {
    use starknet::ContractAddress;
    use src::strk::erc20_lockable::ERC20Lockable;
    use src::token_bridge::TokenBridge;
    use src::token_bridge::TokenBridge::{
        Event, L1BridgeSet, Erc20ClassHashStored, DeployHandled, WithdrawInitiated, DepositHandled,
        deposit_handled, DepositWithMessageHandled, withdraw_initiated, AppRoleAdminAdded,
        AppRoleAdminRemoved, UpgradeGovernorAdded, SecurityAdminAdded, SecurityAdminRemoved,
        SecurityAgentAdded, SecurityAgentRemoved, UpgradeGovernorRemoved, GovernanceAdminAdded,
        GovernanceAdminRemoved, AppGovernorAdded, AppGovernorRemoved, OperatorAdded,
        OperatorRemoved, TokenAdminAdded, TokenAdminRemoved
    };
    use src::access_control_interface::{
        IAccessControl, IAccessControlDispatcher, IAccessControlDispatcherTrait, RoleId,
        RoleAdminChanged, RoleGranted, RoleRevoked
    };
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use src::test_utils::test_utils::{
        caller, not_caller, set_contract_address_as_caller, pop_and_deserialize_last_event,
        pop_last_k_events, deserialize_event, arbitrary_event, assert_role_granted_event,
        assert_role_revoked_event, validate_empty_event_queue, get_roles, get_access_control,
        deploy_token_bridge, get_token_bridge, deploy_new_token, deploy_new_token_and_deposit,
        simple_deploy_lockable_token, get_erc20_token,
    };
    use src::roles_interface::{
        APP_GOVERNOR, APP_ROLE_ADMIN, GOVERNANCE_ADMIN, OPERATOR, TOKEN_ADMIN, UPGRADE_GOVERNOR,
        SECURITY_ADMIN, SECURITY_AGENT, IRolesDispatcher, IRolesDispatcherTrait
    };


    // Validates is_app_governor function, under the assumption that register_app_role_admin and
    // register_app_governor, function as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the App Governor role.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_app_governor(account: arbitrary_account);

        assert(token_bridge_roles.is_app_governor(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_app_role_admin function, under the assumption that register_app_role_admin,
    // functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_app_role_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary_account the App Role Admin role by the caller.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: arbitrary_account);

        assert(
            token_bridge_roles.is_app_role_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_governance_admin function, under the assumption that register_governance_admin,
    // functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_governance_admin() {
        let contract_address = deploy_token_bridge();
        _test_is_governance_admin(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_is_governance_admin() {
        let contract_address = simple_deploy_lockable_token();
        _test_is_governance_admin(:contract_address);
    }

    fn _test_is_governance_admin(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        assert(!_roles.is_governance_admin(account: arbitrary_account), 'Unexpected role detected');

        // Grant the arbitrary_account the Governance Admin role by the caller.
        let _roles = get_roles(contract_address: contract_address);
        _roles.register_governance_admin(account: arbitrary_account);

        assert(_roles.is_governance_admin(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_operator_admin function, under the assumption that register_app_role_admin and
    // register_operator, function as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_operator() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the Operator role.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_operator(account: arbitrary_account);

        assert(token_bridge_roles.is_operator(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_token_admin function, under the assumption that register_app_role_admin and
    // register_token_admin, function as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the caller the App Role Admin role and then the caller grant the arbitrary_account
        // the Token Admin role.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());
        token_bridge_roles.register_token_admin(account: arbitrary_account);

        assert(token_bridge_roles.is_token_admin(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_upgrade_governor function, under the assumption that register_upgrade_governor,
    // functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_upgrade_governor() {
        let contract_address = deploy_token_bridge();
        _test_is_upgrade_governor(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_is_upgrade_governor() {
        let contract_address = simple_deploy_lockable_token();
        _test_is_upgrade_governor(:contract_address);
    }

    fn _test_is_upgrade_governor(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        assert(!_roles.is_upgrade_governor(account: arbitrary_account), 'Unexpected role detected');

        // Grant the arbitrary account the Upgrade Governor role.
        let _roles = get_roles(contract_address: contract_address);
        _roles.register_upgrade_governor(account: arbitrary_account);

        assert(_roles.is_upgrade_governor(account: arbitrary_account), 'Role not granted');
    }

    // Validates is_security_admin function, under the assumption that register_security_admin,
    // functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_security_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_security_admin(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary account the Security Admin role.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_admin(account: arbitrary_account);

        assert(
            token_bridge_roles.is_security_admin(account: arbitrary_account), 'Role not granted'
        );
    }

    // Validates is_security_agent function, under the assumption that register_security_agent,
    // function as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_is_security_agent() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_security_agent(account: arbitrary_account),
            'Unexpected role detected'
        );

        // Grant the arbitrary account the Security Agent role.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_agent(account: arbitrary_account);

        assert(
            token_bridge_roles.is_security_agent(account: arbitrary_account), 'Role not granted'
        );
    }


    // Validates register_app_governor and remove_app_governor functions under the assumption
    // that is_app_governor functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant App Governor role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_app_governor(account: arbitrary_account);
        assert(
            token_bridge_roles.is_app_governor(account: arbitrary_account),
            'register_app_governor failed'
        );

        // Validate the two App Governor registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: APP_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == AppGovernorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'AppGovAdded was not emitted'
        );

        token_bridge_roles.remove_app_governor(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_app_governor(account: arbitrary_account),
            'remove_app_governor failed'
        );

        // Validate the two App Governor removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: APP_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );
        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == AppGovernorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'AppGovRemoved was not emitted'
        );
    }

    // Validates register_app_role_admin and remove_app_role_admin functions under the assumption
    // that is_app_role_admin, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_app_role_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_app_role_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'register_app_role_admin failed'
        );

        // Validate the two App Role Admin registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: APP_ROLE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == AppRoleAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'AppRoleAdminAdded wasnt emitted'
        );

        token_bridge_roles.remove_app_role_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_app_role_admin(account: arbitrary_account),
            'remove_app_role_admin failed'
        );

        // Validate the two App Role Admin removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: APP_ROLE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == AppRoleAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'AppRoleAdminRemoved not emitted'
        );
    }

    // Validates register_governance_admin and remove_governance_admin functions under the
    // assumption that is_governance_admin, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_governance_admin() {
        let contract_address = deploy_token_bridge();
        _test_register_and_remove_governance_admin(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_register_and_remove_governance_admin() {
        let contract_address = simple_deploy_lockable_token();
        _test_register_and_remove_governance_admin(:contract_address);
    }

    fn _test_register_and_remove_governance_admin(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        assert(!_roles.is_governance_admin(account: arbitrary_account), 'Unexpected role detected');
        _roles.register_governance_admin(account: arbitrary_account);
        assert(
            _roles.is_governance_admin(account: arbitrary_account), 'register_governance_adm failed'
        );

        // Validate the two Governance Admin registration events.
        let registration_events = pop_last_k_events(address: contract_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: GOVERNANCE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == GovernanceAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'GovAdminAdded was not emitted'
        );

        _roles.remove_governance_admin(account: arbitrary_account);
        assert(
            !_roles.is_governance_admin(account: arbitrary_account),
            'remove_governance_admin failed'
        );

        // Validate the two Governance Admin removal events.
        let removal_events = pop_last_k_events(address: contract_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: GOVERNANCE_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == GovernanceAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'GovAdminRemoved was not emitted'
        );
    }

    // Validates register_operator and remove_operator functions under the assumption
    // that is_operator functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_operator() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant Operator role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_operator(account: arbitrary_account);
        assert(
            token_bridge_roles.is_operator(account: arbitrary_account), 'register_operator failed'
        );

        // Validate the two Operator registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: OPERATOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == OperatorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'OperatorAdded was not emitted'
        );

        token_bridge_roles.remove_operator(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_operator(account: arbitrary_account), 'remove_operator failed'
        );

        // Validate the two Operator removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: OPERATOR,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == OperatorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'OperatorRemoved was not emitted'
        );
    }


    // Validates register_token_admin and remove_token_admin functions under the assumption
    // that is_token_admin functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        // Grant the caller App Role Admin role, in order to allow him to grant Token Admin role.
        token_bridge_roles.register_app_role_admin(account: caller());

        token_bridge_roles.register_token_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_token_admin(account: arbitrary_account),
            'register_token_admin failed'
        );

        // Validate the two Token Admin registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: TOKEN_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == TokenAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'TokenAdminAdded was not emitted'
        );

        token_bridge_roles.remove_token_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_token_admin(account: arbitrary_account),
            'remove_token_admin failed'
        );

        // Validate the two Token Admin removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: TOKEN_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );
        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == TokenAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'TokenAdminRemoved wasnt emitted'
        );
    }


    // Validates register_upgrade_governor and remove_upgrade_governor functions under the
    // assumption that is_upgrade_governor, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_upgrade_governor() {
        let contract_address = deploy_token_bridge();
        _test_register_and_remove_upgrade_governor(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_register_and_remove_upgrade_governor() {
        let contract_address = simple_deploy_lockable_token();
        _test_register_and_remove_upgrade_governor(:contract_address);
    }

    fn _test_register_and_remove_upgrade_governor(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        assert(!_roles.is_upgrade_governor(account: arbitrary_account), 'Unexpected role detected');
        _roles.register_upgrade_governor(account: arbitrary_account);
        assert(
            _roles.is_upgrade_governor(account: arbitrary_account), 'register_upgrade_gov failed'
        );

        // Validate the two Upgrade Governor registration events.
        let registration_events = pop_last_k_events(address: contract_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: UPGRADE_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == UpgradeGovernorAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'UpgradeGovAdded was not emitted'
        );

        _roles.remove_upgrade_governor(account: arbitrary_account);
        assert(
            !_roles.is_upgrade_governor(account: arbitrary_account),
            'remove_upgrade_governor failed'
        );

        // Validate the two Upgrade Governor removal events.
        let removal_events = pop_last_k_events(address: contract_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: UPGRADE_GOVERNOR,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == UpgradeGovernorRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'UpgradeGovRemoved wasnt emitted'
        );
    }

    // Validates register_security_admin and remove_security_admin functions under the
    // assumption that is_security_admin, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_security_admin() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_security_admin(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_security_admin(account: arbitrary_account);
        assert(
            token_bridge_roles.is_security_admin(account: arbitrary_account),
            'register_security_admin failed'
        );

        // Validate the two Upgrade Governor registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: SECURITY_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == SecurityAdminAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'SecurAdminAdded was not emitted'
        );

        token_bridge_roles.remove_security_admin(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_security_admin(account: arbitrary_account),
            'remove_security_admin failed'
        );

        // Validate the two Upgrade Governor removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: SECURITY_ADMIN,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == SecurityAdminRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'SecurAdminRemoved wasnt emitted'
        );
    }

    // Validates register_security_agent and remove_security_agent functions under the
    // assumption that is_security_agent, functions as expected.
    #[test]
    #[available_gas(30000000)]
    fn test_register_and_remove_security_agent() {
        let token_bridge_address = deploy_token_bridge();

        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_roles.is_security_agent(account: arbitrary_account),
            'Unexpected role detected'
        );
        token_bridge_roles.register_security_agent(account: arbitrary_account);
        assert(
            token_bridge_roles.is_security_agent(account: arbitrary_account),
            'register_security_agent failed'
        );

        // Validate the two Upgrade Governor registration events.
        let registration_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_granted_event(
            raw_event: *registration_events.at(0),
            role: SECURITY_AGENT,
            account: arbitrary_account,
            sender: caller()
        );

        let registration_emitted_event = deserialize_event(raw_event: *registration_events.at(1));
        assert(
            registration_emitted_event == SecurityAgentAdded {
                added_account: arbitrary_account, added_by: caller()
            },
            'SecurAgentAdded was not emitted'
        );

        token_bridge_roles.remove_security_agent(account: arbitrary_account);
        assert(
            !token_bridge_roles.is_security_agent(account: arbitrary_account),
            'remove_security_agent failed'
        );

        // Validate the two Upgrade Governor removal events.
        let removal_events = pop_last_k_events(address: token_bridge_address, k: 2);

        assert_role_revoked_event(
            raw_event: *removal_events.at(0),
            role: SECURITY_AGENT,
            account: arbitrary_account,
            sender: caller()
        );

        let removal_emitted_event = deserialize_event(raw_event: *removal_events.at(1));
        assert(
            removal_emitted_event == SecurityAgentRemoved {
                removed_account: arbitrary_account, removed_by: caller()
            },
            'SecurAgentRemoved wasnt emitted'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_renounce() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let contract_address = deploy_token_bridge();
        _test_renounce(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_renounce() {
        let contract_address = simple_deploy_lockable_token();
        _test_renounce(:contract_address);
    }

    fn _test_renounce(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        _roles.register_upgrade_governor(account: arbitrary_account);
        assert(
            _roles.is_upgrade_governor(account: arbitrary_account), 'register_upgrade_gov failed'
        );

        starknet::testing::set_contract_address(address: arbitrary_account);
        _roles.renounce(role: UPGRADE_GOVERNOR);
        assert(!_roles.is_upgrade_governor(account: arbitrary_account), 'renounce failed');

        // Validate event emission.
        let role_revoked_emitted_event = pop_and_deserialize_last_event(address: contract_address);
        assert(
            role_revoked_emitted_event == Event::RoleRevoked(
                RoleRevoked {
                    role: UPGRADE_GOVERNOR, account: arbitrary_account, sender: arbitrary_account
                }
            ),
            'RoleRevoked was not emitted'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_void_renounce() {
        let contract_address = deploy_token_bridge();
        _test_void_renounce(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_void_renounce() {
        let contract_address = simple_deploy_lockable_token();
        _test_void_renounce(:contract_address);
    }

    fn _test_void_renounce(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        let arbitrary_account = not_caller();
        assert(!_roles.is_upgrade_governor(account: arbitrary_account), 'Unexpected role detected');

        // Empty the event queue.
        pop_last_k_events(address: contract_address, k: 1);

        // The caller, which does not have an Upgrade Governor role, try to renounce this role.
        // Nothing should happen.
        _roles.renounce(role: UPGRADE_GOVERNOR);
        assert(!_roles.is_upgrade_governor(account: arbitrary_account), 'Unexpected role detected');
        validate_empty_event_queue(contract_address);
    }

    #[test]
    #[should_panic(expected: ('GOV_ADMIN_CANNOT_SELF_REMOVE', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_renounce_governance_admin() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let contract_address = deploy_token_bridge();
        _test_renounce_governance_admin(:contract_address);
    }

    #[test]
    #[should_panic(expected: ('GOV_ADMIN_CANNOT_SELF_REMOVE', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_locakable_renounce_governance_admin() {
        let contract_address = simple_deploy_lockable_token();
        _test_renounce_governance_admin(:contract_address);
    }

    fn _test_renounce_governance_admin(contract_address: ContractAddress) {
        let _roles = get_roles(contract_address: contract_address);
        _roles.renounce(role: GOVERNANCE_ADMIN);
    }

    // Tests the functionality of the internal function grant_role_and_emit
    // which is commonly used by all role registration functions.
    #[test]
    #[available_gas(30000000)]
    fn test_grant_role_and_emit() {
        let contract_address = deploy_token_bridge();
        _test_grant_role_and_emit(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_grant_role_and_emit() {
        let contract_address = simple_deploy_lockable_token();
        _test_grant_role_and_emit(:contract_address);
    }

    fn _test_grant_role_and_emit(contract_address: ContractAddress) {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let token_bridge_acess_control = get_access_control(contract_address: contract_address);

        // Set admin_of_arbitrary_role as an admin role of arbitrary_role and then grant the caller
        // the role of admin_of_arbitrary_role.
        let arbitrary_role = 'ARBITRARY';
        let admin_of_arbitrary_role = 'ADMIN_OF_ARBITRARY';

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: contract_address);
        TokenBridge::InternalAccessControl::_set_role_admin(
            ref token_bridge_state, role: arbitrary_role, admin_role: admin_of_arbitrary_role
        );
        TokenBridge::InternalAccessControl::_grant_role(
            ref token_bridge_state, role: admin_of_arbitrary_role, account: caller()
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        let arbitrary_account = not_caller();
        assert(
            !token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'Account should not have role'
        );

        // Set caller address for the _grant_role_and_emit.
        starknet::testing::set_caller_address(address: caller());

        // Set the token bridge address to be the contract address since we are calling internal
        // functions later.
        starknet::testing::set_contract_address(address: contract_address);

        // The caller grant arbitrary_account the role of arbitrary_role.
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_1';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::RolesInternal::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        assert(
            token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'grant_role to account failed'
        );

        // Validate event emission.
        let arbitrary_emitted_event = pop_and_deserialize_last_event(address: contract_address);
        assert(
            arbitrary_emitted_event == RoleAdminChanged {
                role, previous_admin_role, new_admin_role
            },
            'Arbitrary event was not emitted'
        );

        // Uneventful success in redundant registration.
        // I.e. If an account holds a role, re-registering it will not fail, but will not incur
        // any state change or emission of event.
        starknet::testing::set_contract_address(address: contract_address);
        TokenBridge::RolesInternal::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
        validate_empty_event_queue(address: contract_address);
    }


    #[test]
    #[should_panic(expected: ('INVALID_ACCOUNT_ADDRESS',))]
    #[available_gas(30000000)]
    fn test_grant_role_and_emit_zero_account() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let arbitrary_role = 'ARBITRARY';
        let zero_account = starknet::contract_address_const::<0>();
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_0';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::RolesInternal::_grant_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: zero_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
    }
    // Tests the functionality of the internal function revoke_role_and_emit which is commonly used
    // by all role removal functions.
    #[test]
    #[available_gas(30000000)]
    fn test_revoke_role_and_emit() {
        let contract_address = deploy_token_bridge();
        _test_revoke_role_and_emit(:contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_revoke_role_and_emit() {
        let contract_address = simple_deploy_lockable_token();
        _test_revoke_role_and_emit(:contract_address);
    }

    fn _test_revoke_role_and_emit(contract_address: ContractAddress) {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        let token_bridge_acess_control = get_access_control(contract_address: contract_address);

        // Set admin_of_arbitrary_role as an admin role of arbitrary_role and then grant the caller
        // the role of admin_of_arbitrary_role.
        let arbitrary_role = 'ARBITRARY';
        let admin_of_arbitrary_role = 'ADMIN_OF_ARBITRARY';

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: contract_address);
        TokenBridge::InternalAccessControl::_set_role_admin(
            ref token_bridge_state, role: arbitrary_role, admin_role: admin_of_arbitrary_role
        );
        TokenBridge::InternalAccessControl::_grant_role(
            ref token_bridge_state, role: admin_of_arbitrary_role, account: caller()
        );

        let arbitrary_account = not_caller();
        TokenBridge::InternalAccessControl::_grant_role(
            ref token_bridge_state, role: arbitrary_role, account: arbitrary_account
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // token_bridge_acess_control dispatcher.
        set_contract_address_as_caller();
        assert(
            token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'grant_role to account failed'
        );
        // Set caller address for the _revoke_role_and_emit.
        starknet::testing::set_caller_address(address: caller());

        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: contract_address);

        // The caller revoke arbitrary_account the role of arbitrary_role.
        let role = 'DUMMY_0';
        let previous_admin_role = 'DUMMY_1';
        let new_admin_role = 'DUMMY_2';
        TokenBridge::RolesInternal::_revoke_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );

        // Set the contract address to be the caller, as we are calling a function from the
        // dispatcher.
        set_contract_address_as_caller();
        assert(
            !token_bridge_acess_control.has_role(role: arbitrary_role, account: arbitrary_account),
            'Revoke role failed'
        );

        // Validate event emission.
        let arbitrary_emitted_event = pop_and_deserialize_last_event(address: contract_address);
        assert(
            arbitrary_emitted_event == RoleAdminChanged {
                role, previous_admin_role, new_admin_role
            },
            'Arbitrary event was not emitted'
        );

        // Uneventful success in redundant removal.
        // I.e. If an account does not hold a role, removing the role will not fail, but will not
        // incur any state change or emission of event.
        starknet::testing::set_contract_address(address: contract_address);
        TokenBridge::RolesInternal::_revoke_role_and_emit(
            ref token_bridge_state,
            role: arbitrary_role,
            account: arbitrary_account,
            event: arbitrary_event(:role, :previous_admin_role, :new_admin_role)
        );
        validate_empty_event_queue(address: contract_address);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_initialize_roles() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        // Validate that by default, 0 is the role admin of all roles.
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: APP_GOVERNOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: APP_ROLE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: GOVERNANCE_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: OPERATOR
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: TOKEN_ADMIN
            ) == 0,
            '0 should be default role admin'
        );
        assert(
            TokenBridge::AccessControlImplExternal::get_role_admin(
                @token_bridge_state, role: UPGRADE_GOVERNOR
            ) == 0,
            '0 should be default role admin'
        );

        // deploy_token_bridge calls the constructor which calls _initialize_roles.
        let token_bridge_address = deploy_token_bridge();
        let token_bridge_acess_control = get_access_control(contract_address: token_bridge_address);

        // Validate that provisional_governance_admin is the GOVERNANCE_ADMIN.
        assert(
            token_bridge_acess_control.has_role(role: GOVERNANCE_ADMIN, account: caller()),
            'grant_role to account failed'
        );

        // Validate that each role has the right role admin.
        assert(
            token_bridge_acess_control.get_role_admin(role: APP_GOVERNOR) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: APP_ROLE_ADMIN) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: GOVERNANCE_ADMIN) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: OPERATOR) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: TOKEN_ADMIN) == APP_ROLE_ADMIN,
            'Expected APP_ROLE_ADMIN'
        );
        assert(
            token_bridge_acess_control.get_role_admin(role: UPGRADE_GOVERNOR) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_initialize_roles() {
        let contract_address = simple_deploy_lockable_token();

        let _acess_control = get_access_control(contract_address: contract_address);

        // Validate that provisional_governance_admin is the GOVERNANCE_ADMIN.
        assert(
            _acess_control.has_role(role: GOVERNANCE_ADMIN, account: caller()),
            'grant_role to account failed'
        );

        assert(
            _acess_control.get_role_admin(role: GOVERNANCE_ADMIN) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
        assert(
            _acess_control.get_role_admin(role: UPGRADE_GOVERNOR) == GOVERNANCE_ADMIN,
            'Expected GOVERNANCE_ADMIN'
        );
    }

    #[test]
    #[should_panic(expected: ('ROLES_ALREADY_INITIALIZED',))]
    #[available_gas(30000000)]
    fn test_initialize_roles_already_set() {
        let mut token_bridge_state = TokenBridge::contract_state_for_testing();

        starknet::testing::set_caller_address(address: not_caller());
        TokenBridge::RolesInternal::_initialize_roles(ref token_bridge_state, not_caller());
        TokenBridge::RolesInternal::_initialize_roles(ref token_bridge_state, not_caller());
    }

    #[test]
    #[should_panic(expected: ('ROLES_ALREADY_INITIALIZED',))]
    #[available_gas(30000000)]
    fn test_lockable_initialize_roles_already_set() {
        let mut _state = ERC20Lockable::contract_state_for_testing();

        starknet::testing::set_caller_address(address: not_caller());
        ERC20Lockable::RolesInternal::_initialize_roles(ref _state, caller());
        ERC20Lockable::RolesInternal::_initialize_roles(ref _state, caller());
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_app_governor() {
        // Deploy the token bridge. As part of it, the caller becomes the Governance Admin.
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_app_governor(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        // Set the token bridge address to be the contract address since we are calling internal
        // funcitons later.
        starknet::testing::set_contract_address(address: token_bridge_address);
        // Set the caller to be arbitrary_account as it is the App Governor.
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_app_governor(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_APP_GOVERNOR',))]
    #[available_gas(30000000)]
    fn test_only_app_governor_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_app_governor(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_operator() {
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_operator(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_operator(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_OPERATOR',))]
    #[available_gas(30000000)]
    fn test_only_operator_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_operator(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_token_admin() {
        let token_bridge_address = deploy_token_bridge();

        // The Governance Admin register the caller as an App Role Admin.
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_app_role_admin(account: caller());

        let arbitrary_account = not_caller();
        token_bridge_roles.register_token_admin(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_token_admin(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_TOKEN_ADMIN',))]
    #[available_gas(30000000)]
    fn test_only_token_admin_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_token_admin(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_upgrade_governor() {
        let token_bridge_address = deploy_token_bridge();

        let arbitrary_account = not_caller();
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_upgrade_governor(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_upgrade_governor(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_lockable_only_upgrade_governor() {
        let contract_address = simple_deploy_lockable_token();

        let _roles = get_roles(contract_address: contract_address);

        let arbitrary_account = not_caller();
        _roles.register_upgrade_governor(account: arbitrary_account);

        let mut _state = ERC20Lockable::contract_state_for_testing();
        starknet::testing::set_contract_address(address: contract_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        ERC20Lockable::RolesInternal::only_upgrade_governor(@_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR',))]
    #[available_gas(30000000)]
    fn test_only_upgrade_governor_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_upgrade_governor(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_UPGRADE_GOVERNOR',))]
    #[available_gas(30000000)]
    fn test_lockable_only_upgrade_governor_negative() {
        let contract_address = simple_deploy_lockable_token();

        let mut _state = ERC20Lockable::contract_state_for_testing();
        starknet::testing::set_contract_address(address: contract_address);
        starknet::testing::set_caller_address(address: not_caller());

        ERC20Lockable::RolesInternal::only_upgrade_governor(@_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_security_admin() {
        let token_bridge_address = deploy_token_bridge();

        let arbitrary_account = not_caller();
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_admin(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_security_admin(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_SECURITY_ADMIN',))]
    #[available_gas(30000000)]
    fn test_only_security_admin_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_security_admin(@token_bridge_state);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_only_security_agent() {
        let token_bridge_address = deploy_token_bridge();

        let arbitrary_account = not_caller();
        let token_bridge_roles = get_roles(contract_address: token_bridge_address);
        token_bridge_roles.register_security_agent(account: arbitrary_account);

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: arbitrary_account);
        TokenBridge::RolesInternal::only_security_agent(@token_bridge_state);
    }

    #[test]
    #[should_panic(expected: ('ONLY_SECURITY_AGENT',))]
    #[available_gas(30000000)]
    fn test_only_security_agent_negative() {
        let token_bridge_address = deploy_token_bridge();

        let mut token_bridge_state = TokenBridge::contract_state_for_testing();
        starknet::testing::set_contract_address(address: token_bridge_address);
        starknet::testing::set_caller_address(address: not_caller());

        TokenBridge::RolesInternal::only_security_agent(@token_bridge_state);
    }
}
