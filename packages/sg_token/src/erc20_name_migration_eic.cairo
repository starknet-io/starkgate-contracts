//! ERC20 Name/Symbol Migration EIC
//!
//! An External Initializer Contract for upgrading legacy ERC20 tokens that store
//! name and symbol as felt252 to the new format using ByteArray.
//!
//! This EIC uses storage slot collision via #[rename()] to:
//! 1. Read the existing felt252 values from ERC20_name and ERC20_symbol slots
//! 2. Convert them to proper ByteArray format
//! 3. Write them back, properly setting pending_word, pending_word_len, and data fields

#[starknet::contract]
pub mod ERC20NameMigrationEIC {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starkware_utils::byte_array::short_string_to_byte_array;
    use starkware_utils::components::replaceability::interface::IEICInitializable;

    #[storage]
    #[allow(starknet::colliding_storage_paths)]
    struct Storage {
        ERC20_name: felt252,
        ERC20_symbol: felt252,
        #[rename("ERC20_name")]
        ERC20_name_ba: ByteArray,
        #[rename("ERC20_symbol")]
        ERC20_symbol_ba: ByteArray,
    }

    #[abi(embed_v0)]
    impl EICInitializable of IEICInitializable<ContractState> {
        fn eic_initialize(ref self: ContractState, eic_init_data: Span<felt252>) {
            assert(eic_init_data.len() == 0, 'NO_EIC_INIT_DATA_EXPECTED');
            // Migrate name: read as felt252, write as ByteArray
            self.ERC20_name_ba.write(short_string_to_byte_array(self.ERC20_name.read()));
            // Migrate symbol: read as felt252, write as ByteArray
            self.ERC20_symbol_ba.write(short_string_to_byte_array(self.ERC20_symbol.read()));
        }
    }
}
