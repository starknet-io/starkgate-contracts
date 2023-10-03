use starknet::ContractAddress;


type RoleId = felt252;

#[starknet::interface]
trait IAccessControl<TContractState> {
    fn has_role(self: @TContractState, role: RoleId, account: ContractAddress) -> bool;
    fn get_role_admin(self: @TContractState, role: RoleId) -> RoleId;
}
