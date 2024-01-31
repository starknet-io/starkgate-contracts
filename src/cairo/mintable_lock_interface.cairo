use starknet::ContractAddress;

#[starknet::interface]
trait IMintableLock<TContractState> {
    fn permissioned_lock_and_delegate(
        ref self: TContractState, account: ContractAddress, delegatee: ContractAddress, amount: u256
    );
}

#[starknet::interface]
trait ILockingContract<TContractState> {
    fn set_locking_contract(ref self: TContractState, locking_contract: ContractAddress);
    fn get_locking_contract(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
trait ILockAndDelegate<TContractState> {
    fn lock_and_delegate(ref self: TContractState, delegatee: ContractAddress, amount: u256);
    fn lock_and_delegate_by_sig(
        ref self: TContractState,
        account: ContractAddress,
        delegatee: ContractAddress,
        amount: u256,
        nonce: felt252,
        expiry: u64,
        signature: Array<felt252>
    );
}

#[starknet::interface]
trait ITokenLock<TContractState> {
    fn lock(ref self: TContractState, amount: u256);
    fn unlock(ref self: TContractState, amount: u256);
}

#[derive(Copy, Drop, PartialEq, starknet::Event)]
struct Locked {
    #[key]
    account: ContractAddress,
    amount: u256
}

#[derive(Copy, Drop, PartialEq, starknet::Event)]
struct Unlocked {
    #[key]
    account: ContractAddress,
    amount: u256
}
