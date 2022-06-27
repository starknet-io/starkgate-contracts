%lang starknet

@contract_interface
namespace Initializable:
    func initialized() -> (res : felt):
    end
    func initialize(init_vector_len : felt, init_vector : felt*):
    end
end

@contract_interface
namespace ExternalInitializer:
    func eic_initialize(init_vector_len : felt, init_vector : felt*):
    end
end
