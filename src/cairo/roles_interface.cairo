use starknet::ContractAddress;

// Role                |   Role Admin
// ----------------------------------------
// GOVERNANCE_ADMIN    |   GOVERNANCE_ADMIN
// UPGRADE_GOVERNOR    |   GOVERNANCE_ADMIN
// APP_ROLE_ADMIN      |   GOVERNANCE_ADMIN
// APP_GOVERNOR        |   APP_ROLE_ADMIN
// OPERATOR            |   APP_ROLE_ADMIN
// TOKEN_ADMIN         |   APP_ROLE_ADMIN.

// int.from_bytes(Web3.keccak(text="ROLE_APP_GOVERNOR"), "big") & MASK_250 .
const APP_GOVERNOR: felt252 = 0xd2ead78c620e94b02d0a996e99298c59ddccfa1d8a0149080ac3a20de06068;

// int.from_bytes(Web3.keccak(text="ROLE_APP_ROLE_ADMIN"), "big") & MASK_250 .
const APP_ROLE_ADMIN: felt252 = 0x3e615638e0b79444a70f8c695bf8f2a47033bf1cf95691ec3130f64939cee99;

// int.from_bytes(Web3.keccak(text="ROLE_GOVERNANCE_ADMIN"), "big") & MASK_250 .
const GOVERNANCE_ADMIN: felt252 = 0x3711c9d994faf6055172091cb841fd4831aa743e6f3315163b06a122c841846;

// int.from_bytes(Web3.keccak(text="ROLE_OPERATOR"), "big") & MASK_250 .
const OPERATOR: felt252 = 0x023edb77f7c8cc9e38e8afe78954f703aeeda7fffe014eeb6e56ea84e62f6da7;

// int.from_bytes(Web3.keccak(text="ROLE_TOKEN_ADMIN"), "big") & MASK_250 .
const TOKEN_ADMIN: felt252 = 0x0128d63adbf6b09002c26caf55c47e2f26635807e3ef1b027218aa74c8d61a3e;

// int.from_bytes(Web3.keccak(text="ROLE_UPGRADE_GOVERNOR"), "big") & MASK_250 .
const UPGRADE_GOVERNOR: felt252 = 0x251e864ca2a080f55bce5da2452e8cfcafdbc951a3e7fff5023d558452ec228;

#[starknet::interface]
trait IRoles<TContractState> {
    fn is_app_governor(self: @TContractState, account: ContractAddress) -> bool;
    fn is_app_role_admin(self: @TContractState, account: ContractAddress) -> bool;
    fn is_governance_admin(self: @TContractState, account: ContractAddress) -> bool;
    fn is_operator(self: @TContractState, account: ContractAddress) -> bool;
    fn is_token_admin(self: @TContractState, account: ContractAddress) -> bool;
    fn is_upgrade_governor(self: @TContractState, account: ContractAddress) -> bool;
    fn register_app_governor(ref self: TContractState, account: ContractAddress);
    fn remove_app_governor(ref self: TContractState, account: ContractAddress);
    fn register_app_role_admin(ref self: TContractState, account: ContractAddress);
    fn remove_app_role_admin(ref self: TContractState, account: ContractAddress);
    fn register_governance_admin(ref self: TContractState, account: ContractAddress);
    fn remove_governance_admin(ref self: TContractState, account: ContractAddress);
    fn register_operator(ref self: TContractState, account: ContractAddress);
    fn remove_operator(ref self: TContractState, account: ContractAddress);
    fn register_token_admin(ref self: TContractState, account: ContractAddress);
    fn remove_token_admin(ref self: TContractState, account: ContractAddress);
    fn register_upgrade_governor(ref self: TContractState, account: ContractAddress);
    fn remove_upgrade_governor(ref self: TContractState, account: ContractAddress);
    fn renounce(ref self: TContractState, role: felt252);
}

#[starknet::interface]
trait IMinimalRoles<TContractState> {
    fn is_governance_admin(self: @TContractState, account: ContractAddress) -> bool;
    fn is_upgrade_governor(self: @TContractState, account: ContractAddress) -> bool;
    fn register_governance_admin(ref self: TContractState, account: ContractAddress);
    fn remove_governance_admin(ref self: TContractState, account: ContractAddress);
    fn register_upgrade_governor(ref self: TContractState, account: ContractAddress);
    fn remove_upgrade_governor(ref self: TContractState, account: ContractAddress);
    fn renounce(ref self: TContractState, role: felt252);
}
