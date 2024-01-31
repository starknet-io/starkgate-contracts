// STRK Token (ERC20Lockable).
mod strk;

// Interfaces.
mod access_control_interface;
mod token_bridge_admin_interface;
mod token_bridge_interface;
mod erc20_interface;
mod mintable_token_interface;
mod mintable_lock_interface;
mod replaceability_interface;
mod roles_interface;
mod receiver_interface;
mod token_test_setup_interface;

// Modules.
mod token_bridge;
mod legacy_bridge_eic;
mod roles_init_eic;
mod update_712_vars_eic;
mod err_msg;

// Tests.
mod test_utils;
mod token_bridge_admin_test;
mod token_bridge_test;
mod roles_test;
mod permissioned_token_test;
mod token_test_setup;
mod stub_msg_receiver;
mod replaceability_test;
mod legacy_bridge_tester;
mod legacy_eic_test;
mod update712_eic_tester;
