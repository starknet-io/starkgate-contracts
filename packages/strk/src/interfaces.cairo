use starknet::ContractAddress;

/// Interface for the locking contract that receives locked tokens and grants voting power.
#[starknet::interface]
pub trait IMintableLock<TContractState> {
    fn permissioned_lock_and_delegate(
        ref self: TContractState,
        account: ContractAddress,
        delegatee: ContractAddress,
        amount: u256,
    );
}

/// Interface to set/get the locking contract address.
#[starknet::interface]
pub trait ILockingContract<TContractState> {
    fn set_locking_contract(ref self: TContractState, locking_contract: ContractAddress);
    fn get_locking_contract(self: @TContractState) -> ContractAddress;
}

/// Interface for lock and delegate operations (on the token side).
#[starknet::interface]
pub trait ILockAndDelegate<TContractState> {
    fn lock_and_delegate(ref self: TContractState, delegatee: ContractAddress, amount: u256);
    fn lock_and_delegate_by_sig(
        ref self: TContractState,
        account: ContractAddress,
        delegatee: ContractAddress,
        amount: u256,
        nonce: felt252,
        expiry: u64,
        signature: Array<felt252>,
    );
}

/// Interface for basic lock/unlock operations (on the voting wrapper side).
#[starknet::interface]
pub trait ITokenLock<TContractState> {
    fn lock(ref self: TContractState, amount: u256);
    fn unlock(ref self: TContractState, amount: u256);
}

/// Event emitted when tokens are locked.
#[derive(Copy, Drop, starknet::Event)]
pub struct Locked {
    #[key]
    pub account: ContractAddress,
    pub amount: u256,
}

/// Event emitted when tokens are unlocked.
#[derive(Copy, Drop, starknet::Event)]
pub struct Unlocked {
    #[key]
    pub account: ContractAddress,
    pub amount: u256,
}
