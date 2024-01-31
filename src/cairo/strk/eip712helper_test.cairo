#[cfg(test)]
mod eip712helper_test {
    use src::test_utils::test_utils::deploy_account;
    use src::strk::eip712helper::{
        pedersen_hash_span, validate_signature, calc_domain_hash, lock_and_delegate_message_hash
    };

    const PUBLIC_KEY: felt252 = 0x3a59358373db02be1870eb01ff39d8cf76139d60bd594ef123e550262ba43ae;
    const MESSAGE_HASH: felt252 = 0x1312;
    const INCORRECT_MESSAGE_HASH: felt252 = 0x1313;
    const SIG_R: felt252 = 0x1b1b51df737f1a26cdcdbda0a2fc16a128a82fd19ea1b4305d152aac756a6c4;
    const SIG_S: felt252 = 0x460c481611160ed8b744e0bfd7e18b7982476c15d3a80cc53af8c43215b7a9f;

    #[test]
    #[available_gas(30000000)]
    fn test_validate_signature_valid_sig() {
        let account_address = deploy_account(public_key: PUBLIC_KEY);
        let sig = array![SIG_R, SIG_S,];
        validate_signature(account: account_address, hash: MESSAGE_HASH, signature: sig);
    }

    #[test]
    #[should_panic(expected: ('SIGNATURE_VALIDATION_FAILED',))]
    #[available_gas(30000000)]
    fn test_validate_signature_invalid_sig() {
        let account_address = deploy_account(public_key: PUBLIC_KEY);
        let sig = array![SIG_R, SIG_S,];
        validate_signature(account: account_address, hash: INCORRECT_MESSAGE_HASH, signature: sig);
    }

    #[test]
    #[available_gas(30000000)]
    fn test_pedersen_hash_span() {
        let mut input_1 = array![1, 2, 3].span();
        assert(
            pedersen_hash_span(
                elements: input_1
            ) == 441445179418634841919081406710178353724709968888928575445243752807295331953,
            'HASH_CHAIN_MISMATCH'
        );

        let mut input_2 = array![1, 1, 2, 3, 5, 8].span();
        assert(
            pedersen_hash_span(
                elements: input_2
            ) == 2383567234044941266234273954434601971633866581716422196120361961392048788157,
            'HASH_CHAIN_MISMATCH'
        );
    }


    fn validate_lock_and_delegate_hash(
        chain_id: felt252, expected_domain_hash: felt252, expected_lock_hash: felt252,
    ) {
        let account = starknet::contract_address_const::<20>();
        let delegatee = starknet::contract_address_const::<21>();
        let amount = 200;
        let nonce = 17;
        let expiry = 1234;

        starknet::testing::set_chain_id(:chain_id);
        assert(calc_domain_hash() == expected_domain_hash, 'DOMAIN_HASH_MISMATCH');
        assert(
            lock_and_delegate_message_hash(
                domain: expected_domain_hash, :account, :delegatee, :amount, :nonce, :expiry
            ) == expected_lock_hash,
            'LOCK_AND_DELEGATE_HASH_MISMATCH'
        );
    }


    #[test]
    #[available_gas(30000000)]
    fn test_lock_and_delegate_message_hash() {
        validate_lock_and_delegate_hash(
            chain_id: 'SN_MAIN',
            expected_domain_hash: 0x23be9c6c2dae4eb0f63f635d0299a52406da231334529560d829dfa505dd102,
            expected_lock_hash: 0x1b1da5b69f289991e11c75383c0ce5c3f5c5dc6412f2ba76d3fdf1d092be046,
        );

        validate_lock_and_delegate_hash(
            chain_id: 'SN_GOERLI',
            expected_domain_hash: 0x7fbbf1a57a6370927e09cad58ccbfbd6b26b1cc6ee639edf8e0e36f020284bb,
            expected_lock_hash: 0x700e4547ec169faac705c3f0bfdca19b12d1477ed0ce9d2f6824d541ce3c43c,
        );

        validate_lock_and_delegate_hash(
            chain_id: 'SN_SEPOLIA',
            expected_domain_hash: 0x2b8163ee3c860582618b34edefdc1afd0511a50fd69016eb92c7dce447fc55d,
            expected_lock_hash: 0x7dcea700fe19c5c1650843c652997e692605f02c9542e1265826b8f138903b4,
        );
    }
}
