// An EIC contract to set the bridge as legacy (vs. multi).
#[starknet::contract]
mod SetAsSingleEIC {
    use starknet::{
        ContractAddress, get_caller_address, EthAddress, EthAddressIntoFelt252, EthAddressSerde
    };
    use src::erc20_interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use src::replaceability_interface::IEICInitializable;

    #[storage]
    struct Storage {
        // --- Token Bridge ---
        // Mapping from between l1<->l2 token addresses.
        l1_l2_token_map: LegacyMap<EthAddress, ContractAddress>,
        l2_l1_token_map: LegacyMap<ContractAddress, EthAddress>,
        // `l2_token` is a legacy storage variable from older versions.
        // It should be written to as well to prevent multiple init, making the bridge a single.
        // and also to support legact L1-L2 msgs.
        l2_token: ContractAddress,
    }

    #[abi(embed_v0)]
    impl EICInitializable of IEICInitializable<ContractState> {
        // Populates L1-L2 & L2-L1 token mapping.
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 2, 'EIC_INIT_DATA_LEN_MISMATCH_2');
            let l1_token: EthAddress = (*eic_init_data[0]).try_into().unwrap();
            let l2_token: ContractAddress = (*eic_init_data[1]).try_into().unwrap();
            self.setup_l1_l2_mappings(:l1_token, :l2_token);
        }
    }

    #[generate_trait]
    impl internals of _internals {
        fn setup_l1_l2_mappings(
            ref self: ContractState, l1_token: EthAddress, l2_token: ContractAddress
        ) {
            assert(self.l2_token.read().is_zero(), 'L2_BRIDGE_ALREADY_INITIALIZED');
            assert(l1_token.is_non_zero(), 'ZERO_L1_TOKEN');
            assert(l2_token.is_non_zero(), 'ZERO_L2_TOKEN');

            // Implicitly assert that the L2 token supports snake case (i.e. already upgraded.)
            IERC20Dispatcher { contract_address: l2_token }.total_supply();

            assert(self.l1_l2_token_map.read(l1_token).is_zero(), 'L2_BRIDGE_ALREADY_INITIALIZED');
            assert(self.l2_l1_token_map.read(l2_token).is_zero(), 'L2_BRIDGE_ALREADY_INITIALIZED');

            self.l2_token.write(l2_token);
            self.l1_l2_token_map.write(l1_token, l2_token);
            self.l2_l1_token_map.write(l2_token, l1_token);
        }
    }
}

