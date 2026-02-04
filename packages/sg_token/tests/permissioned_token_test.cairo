//! Tests for permissioned token (mint/burn) functionality.
//! These tests apply to both ERC20Mintable (sg_token) and ERC20Lockable (strk).

use core::num::traits::Bounded;
use openzeppelin_interfaces::erc20::IERC20DispatcherTrait;
use starknet::ContractAddress;
use starkware_utils::interfaces::mintable_token::IMintableTokenDispatcherTrait;
use super::test_utils::{deploy_l2_token, get_erc20_token, get_mintable_token};

#[test]
fn test_erc20_successful_permitted_mint() {
    let initial_owner = 10.try_into().unwrap();
    let permitted_minter = 20.try_into().unwrap();
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);

    let erc20_token = get_erc20_token(l2_token);
    let mintable_token = get_mintable_token(l2_token);

    // Permissioned mint using the permitted minter address
    starknet::testing::set_contract_address(permitted_minter);

    let minted_amount = 200;
    let total_before = erc20_token.total_supply();
    assert(erc20_token.balance_of(initial_owner) == total_before, 'BAD_BALANCE_TEST_SETUP');

    // Mint to a new address
    let mint_recipient: ContractAddress = 1337.try_into().unwrap();
    mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
    assert(erc20_token.balance_of(mint_recipient) == minted_amount, 'NEW_ADDR_PERM_MINT_ERROR');

    // Mint to an address with existing balance
    mintable_token.permissioned_mint(account: initial_owner, amount: minted_amount);
    assert(
        erc20_token.balance_of(initial_owner) == total_before + minted_amount,
        'USED_ADDR_PERM_MINT_ERROR',
    );

    // Verify total supply
    assert(
        erc20_token.total_supply() == total_before + 2 * minted_amount,
        'TOTAL_SUPPLY_PERM_MINT_ERROR',
    );
}

#[test]
#[should_panic(expected: ('u256_add Overflow', 'ENTRYPOINT_FAILED'))]
fn test_erc20_overflowing_permitted_mint() {
    // Setup
    let initial_owner: ContractAddress = 10.try_into().unwrap();
    let permitted_minter: ContractAddress = 20.try_into().unwrap();
    let max_u256: u256 = Bounded::MAX;

    // Deploy the l2 token contract with max supply
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: max_u256);

    let mintable_token = get_mintable_token(l2_token);

    // Permissioned mint that results in an overflow (max + 1)
    starknet::testing::set_contract_address(permitted_minter);
    let mint_recipient: ContractAddress = 1337.try_into().unwrap();
    mintable_token.permissioned_mint(account: mint_recipient, amount: 1);
}

#[test]
#[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED'))]
fn test_erc20_unpermitted_permitted_mint() {
    let initial_owner: ContractAddress = 10.try_into().unwrap();
    let permitted_minter: ContractAddress = 20.try_into().unwrap();
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);

    let mintable_token = get_mintable_token(l2_token);

    // Permissioned mint using an unpermitted minter address
    let unpermitted_minter: ContractAddress = 1234.try_into().unwrap();
    starknet::testing::set_contract_address(unpermitted_minter);
    let mint_recipient: ContractAddress = 1337.try_into().unwrap();
    mintable_token.permissioned_mint(account: mint_recipient, amount: 200);
}

#[test]
fn test_erc20_successful_permitted_burn() {
    let initial_owner: ContractAddress = 10.try_into().unwrap();
    let permitted_minter: ContractAddress = 20.try_into().unwrap();
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);

    let erc20_token = get_erc20_token(l2_token);
    let mintable_token = get_mintable_token(l2_token);

    // Permissioned burn using the permitted minter address
    starknet::testing::set_contract_address(permitted_minter);

    let burnt_amount = 200;
    let before_amount = erc20_token.total_supply();
    let expected_after = before_amount - burnt_amount;

    // Burn from an address with existing balance
    mintable_token.permissioned_burn(account: initial_owner, amount: burnt_amount);
    assert(erc20_token.balance_of(initial_owner) == expected_after, 'USED_ADDR_PERM_BURN_ERROR');

    // Verify total supply
    assert(erc20_token.total_supply() == expected_after, 'TOTAL_SUPPLY_PERM_BURN_ERROR');
}

#[test]
#[should_panic(expected: ('ERC20: insufficient balance', 'ENTRYPOINT_FAILED'))]
fn test_erc20_exceeding_amount_permitted_burn() {
    // Setup
    let initial_owner: ContractAddress = 10.try_into().unwrap();
    let permitted_minter: ContractAddress = 20.try_into().unwrap();

    // Deploy the l2 token contract
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);

    let mintable_token = get_mintable_token(l2_token);

    // Permissioned burn of an exceeding amount
    starknet::testing::set_contract_address(permitted_minter);
    mintable_token.permissioned_burn(account: initial_owner, amount: 1001);
}

#[test]
#[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED'))]
fn test_erc20_unpermitted_permitted_burn() {
    // Setup
    let initial_owner: ContractAddress = 10.try_into().unwrap();
    let permitted_minter: ContractAddress = 20.try_into().unwrap();

    // Deploy the l2 token contract
    let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);

    let mintable_token = get_mintable_token(l2_token);

    // Permissioned burn using an unpermitted minter address
    let unpermitted_minter: ContractAddress = 1234.try_into().unwrap();
    starknet::testing::set_contract_address(unpermitted_minter);
    mintable_token.permissioned_burn(account: initial_owner, amount: 200);
}
// Note: test_init_invalid_minter_address is now a unit test in src/erc20_mintable.cairo
// because cairo_test can properly catch deploy_syscall errors with unwrap_err().


