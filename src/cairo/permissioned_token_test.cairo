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

    use super::super::mintable_token_interface::{
        IMintableTokenDispatcher, IMintableTokenDispatcherTrait
    };
    use super::super::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::test_utils::test_utils::{
        get_erc20_token, deploy_l2_votes_token, deploy_l2_token, get_mintable_token,
        get_l2_token_deployment_calldata
    };

    use super::super::permissioned_erc20::PermissionedERC20;
    use openzeppelin::token::erc20::presets::erc20votes::ERC20VotesPreset;

    #[test]
    #[available_gas(30000000)]
    fn test_successful_erc20_votes_permitted_mint() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<1023>();
        let permitted_minter = starknet::contract_address_const::<2047>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: 1000_u256
        );
        let erc20_token = get_erc20_token(:l2_token_address);
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned mint using the permitter minter address.
        starknet::testing::set_contract_address(permitted_minter);
        let minted_amount = 200_u256;

        // Mint to a new address.
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
        assert(erc20_token.balance_of(mint_recipient) == minted_amount, 'NEW_ADDR_PERM_MINT_ERROR');

        // Mint to an address with existing balance.
        mintable_token.permissioned_mint(account: initial_owner, amount: minted_amount);
        assert(erc20_token.balance_of(initial_owner) == 1200_u256, 'USED_ADDR_PERM_MINT_ERROR');

        // Verify total supply.
        assert(erc20_token.total_supply() == 1400_u256, 'TOTAL_SUPPLY_PERM_MINT_ERROR');
    }


    #[test]
    #[available_gas(30000000)]
    fn test_successful_permitted_mint() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_token(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );
        let erc20_token = get_erc20_token(:l2_token_address);
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned mint using the permitter minter address.
        starknet::testing::set_contract_address(permitted_minter);
        let minted_amount = 200;

        // Mint to a new address.
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
        assert(erc20_token.balance_of(mint_recipient) == minted_amount, 'NEW_ADDR_PERM_MINT_ERROR');

        // Mint to an address with existing balance.
        mintable_token.permissioned_mint(account: initial_owner, amount: minted_amount);
        assert(erc20_token.balance_of(initial_owner) == 1200, 'USED_ADDR_PERM_MINT_ERROR');

        // Verify total supply.
        assert(erc20_token.total_supply() == 1400, 'TOTAL_SUPPLY_PERM_MINT_ERROR');
    }

    #[test]
    #[should_panic(expected: ('u256_add Overflow', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_overflowing_permitted_mint() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();
        let max_u256: u256 = BoundedInt::max();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: max_u256
        );
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned mint that results in an overflow (max + 1).
        starknet::testing::set_contract_address(permitted_minter);
        let minted_amount = 1;
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
    }

    #[test]
    #[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_unpermitted_permitted_mint() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned mint using an unpermitter minter address.
        let unpermitted_minter = starknet::contract_address_const::<1234>();
        starknet::testing::set_contract_address(unpermitted_minter);
        let minted_amount = 200;
        let mint_recipient = starknet::contract_address_const::<1337>();
        mintable_token.permissioned_mint(account: mint_recipient, amount: minted_amount);
    }


    #[test]
    #[available_gas(30000000)]
    fn test_init_invalid_minter_address() {
        // Setup with a zero minter.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<0>();

        let calldata = get_l2_token_deployment_calldata(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );

        // Deploy the contract.
        let error_message = deploy_syscall(
            PermissionedERC20::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata, false
        )
            .unwrap_err()
            .span();
        assert(error_message.len() == 2, 'UNEXPECTED_ERROR_LEN_MISMATCH');
        assert(error_message.at(0) == @'INVALID_MINTER_ADDRESS', 'INVALID_MINTER_ADDRESS_ERROR');
        assert(error_message.at(1) == @'CONSTRUCTOR_FAILED', 'CONSTRUCTOR_ERROR_MISMATCH');
    }

    #[test]
    #[available_gas(30000000)]
    fn test_successful_permitted_burn() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );
        let erc20_token = get_erc20_token(:l2_token_address);
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned burn using the permitter minter address.
        starknet::testing::set_contract_address(permitted_minter);
        let burnt_amount = 200;

        // Burn from an address with existing balance.
        mintable_token.permissioned_burn(account: initial_owner, amount: burnt_amount);
        assert(erc20_token.balance_of(initial_owner) == 800, 'USED_ADDR_PERM_BURN_ERROR');

        // Verify total supply.
        assert(erc20_token.total_supply() == 800, 'TOTAL_SUPPLY_PERM_BURN_ERROR');
    }

    #[test]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_exceeding_amount_permitted_burn() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned burn of an exceeding amount.
        starknet::testing::set_contract_address(permitted_minter);
        let burnt_amount = 1001;
        mintable_token.permissioned_burn(account: initial_owner, amount: burnt_amount);
    }

    #[test]
    #[should_panic(expected: ('MINTER_ONLY', 'ENTRYPOINT_FAILED',))]
    #[available_gas(30000000)]
    fn test_unpermitted_permitted_burn() {
        // Setup.
        let initial_owner = starknet::contract_address_const::<10>();
        let permitted_minter = starknet::contract_address_const::<20>();

        // Deploy the l2 token contract.
        let l2_token_address = deploy_l2_votes_token(
            :initial_owner, :permitted_minter, initial_supply: 1000
        );
        let mintable_token = get_mintable_token(:l2_token_address);

        // Permissioned burn using an unpermitter minter address.
        let unpermitted_minter = starknet::contract_address_const::<1234>();
        starknet::testing::set_contract_address(unpermitted_minter);
        let burnt_amount = 200;
        mintable_token.permissioned_burn(account: initial_owner, amount: burnt_amount);
    }
}
