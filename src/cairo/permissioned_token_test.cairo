#[cfg(test)]
mod permissioned_token_test {
    use array::ArrayTrait;
    use array::SpanTrait;
    use core::traits::Into;
    use core::result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use integer::BoundedInt;
    use serde::Serde;
    use starknet::{contract_address_const, ContractAddress, syscalls::deploy_syscall};
    use src::err_msg::AccessErrors as AccessErrors;

    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::test_utils::test_utils::{
        get_erc20_token, deploy_l2_token, get_mintable_token, get_l2_token_deployment_calldata
    };

    use openzeppelin::token::erc20::presets::erc20_votes_lock::ERC20VotesLock;
    use openzeppelin::token::erc20_v070::erc20::ERC20;

    fn _l2_erc20(initial_supply: u256) -> ContractAddress {
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        deploy_l2_token(:initial_owner, :permitted_minter, :initial_supply)
    }

    #[test]
    #[available_gas(30000000)]
    fn test_erc20_successful_permitted_mint() {
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);
        _successful_permitted_mint(:l2_token, :initial_owner, :permitted_minter);
    }

    fn _successful_permitted_mint(
        l2_token: ContractAddress, initial_owner: ContractAddress, permitted_minter: ContractAddress
    ) {
        let erc20_token = get_erc20_token(:l2_token);
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned mint using the permitter minter address.
        starknet::testing::set_contract_address(permitted_minter);
        let minted_amount = 200;
        let total_before = erc20_token.total_supply();
        assert(erc20_token.balance_of(initial_owner) == total_before, 'BAD_BALANCE_TEST_SETUP');

        // Mint to a new address.
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
        assert(erc20_token.balance_of(mint_recipient) == minted_amount, 'NEW_ADDR_PERM_MINT_ERROR');

        // Mint to an address with existing balance.
        mintable_token.permissioned_mint(account: initial_owner, amount: minted_amount);
        assert(
            erc20_token.balance_of(initial_owner) == total_before + minted_amount,
            'USED_ADDR_PERM_MINT_ERROR'
        );

        // Verify total supply.
        assert(
            erc20_token.total_supply() == total_before + 2 * minted_amount,
            'TOTAL_SUPPLY_PERM_MINT_ERROR'
        );
    }

    #[test]
    #[should_panic(expected: ('u256_add Overflow', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_erc20_overflowing_permitted_mint() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let max_u256: u256 = BoundedInt::max();

        // Deploy the l2 token contract.
        let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: max_u256);
        _overflowing_permitted_mint(:l2_token, :initial_owner, :permitted_minter);
    }

    fn _overflowing_permitted_mint(
        l2_token: ContractAddress, initial_owner: ContractAddress, permitted_minter: ContractAddress
    ) {
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned mint that results in an overflow (max + 1).
        starknet::testing::set_contract_address(permitted_minter);
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: 1);
        let max_u255 = u256 {
            low: 0xffffffffffffffffffffffffffffffff, high: 0x7fffffffffffffffffffffffffffffff
        };
        mintable_token.permissioned_mint(account: mint_recipient, amount: max_u255);
    }

    #[test]
    #[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_erc20_unpermitted_permitted_mint() {
        let l2_token = _l2_erc20(initial_supply: 1000);
        _unpermitted_permitted_mint(:l2_token);
    }

    fn _unpermitted_permitted_mint(l2_token: ContractAddress) {
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned mint using an unpermitter minter address.
        let unpermitted_minter = starknet::contract_address_const::<1234>();
        starknet::testing::set_contract_address(unpermitted_minter);
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: 200);
    }


    #[test]
    #[available_gas(30000000)]
    fn test_init_invalid_minter_address() {
        // Setup with a zero minter.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<0>();

        let calldata = get_l2_token_deployment_calldata(
            :initial_owner, :permitted_minter, token_gov: permitted_minter, initial_supply: 1000
        );

        // Deploy the contract.
        let error_message = deploy_syscall(
            ERC20::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false
        )
            .unwrap_err()
            .span();
        assert(error_message.len() == 2, 'UNEXPECTED_ERROR_LEN_MISMATCH');
        assert(
            error_message.at(0) == @AccessErrors::INVALID_MINTER, 'INVALID_MINTER_ADDRESS_ERROR'
        );
        assert(error_message.at(1) == @'CONSTRUCTOR_FAILED', 'CONSTRUCTOR_ERROR_MISMATCH');
    }

    #[test]
    #[available_gas(30000000)]
    fn test_erc20_successful_permitted_burn() {
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);
        _successful_permitted_burn(:l2_token, :initial_owner, :permitted_minter);
    }

    fn _successful_permitted_burn(
        l2_token: ContractAddress, initial_owner: ContractAddress, permitted_minter: ContractAddress
    ) {
        let erc20_token = get_erc20_token(:l2_token);
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned burn using the permitter minter address.
        starknet::testing::set_contract_address(permitted_minter);
        let burnt_amount = 200;
        let before_amount = erc20_token.total_supply();
        let expected_after = before_amount - burnt_amount;

        // Burn from an address with existing balance.
        mintable_token.permissioned_burn(account: initial_owner, amount: burnt_amount);
        assert(
            erc20_token.balance_of(initial_owner) == expected_after, 'USED_ADDR_PERM_BURN_ERROR'
        );

        // Verify total supply.
        assert(erc20_token.total_supply() == expected_after, 'TOTAL_SUPPLY_PERM_BURN_ERROR');
    }

    #[test]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_erc20_exceeding_amount_permitted_burn() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);
        _exceeding_amount_permitted_burn(:l2_token, :initial_owner, :permitted_minter);
    }

    fn _exceeding_amount_permitted_burn(
        l2_token: ContractAddress, initial_owner: ContractAddress, permitted_minter: ContractAddress
    ) {
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned burn of an exceeding amount.
        starknet::testing::set_contract_address(permitted_minter);
        mintable_token.permissioned_burn(account: initial_owner, amount: 1001);
    }

    #[test]
    #[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_erc20_unpermitted_permitted_burn() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token = deploy_l2_token(:initial_owner, :permitted_minter, initial_supply: 1000);
        _unpermitted_permitted_burn(:l2_token, :initial_owner, :permitted_minter);
    }

    fn _unpermitted_permitted_burn(
        l2_token: ContractAddress, initial_owner: ContractAddress, permitted_minter: ContractAddress
    ) {
        let mintable_token = get_mintable_token(:l2_token);

        // Permissioned burn using an unpermitter minter address.
        let unpermitted_minter = starknet::contract_address_const::<1234>();
        starknet::testing::set_contract_address(unpermitted_minter);
        mintable_token.permissioned_burn(account: initial_owner, amount: 200);
    }
}
