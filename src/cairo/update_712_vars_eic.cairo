// An External Initializer Contract to fix erc20votes eip712 dapp_name & dapp_version constants.
// This update is needed as OZ changed the storage var names, and SW changed the constants.
#[starknet::contract]
mod Update712VarsEIC {
    use super::super::replaceability_interface::IEICInitializable;
    use openzeppelin::token::erc20::presets::erc20_votes_lock::ERC20VotesLock::{
        DAPP_NAME, DAPP_VERSION
    };

    #[storage]
    struct Storage {
        EIP712_name: felt252,
        EIP712_version: felt252
    }

    #[external(v0)]
    impl EICInitializable of IEICInitializable<ContractState> {
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 0, 'NO_EIC_INIT_DATA_EXPECTED');
            self.EIP712_name.write(DAPP_NAME);
            self.EIP712_version.write(DAPP_VERSION);
        }
    }
}

