python_lib(starknet_governance_sol
    PREFIX starkware/starknet/eth
    FILES
    StarknetGovernance.sol

    LIBS
    governance_contract_sol
)

python_lib(starknet_messaging_sol
    PREFIX starkware/starknet/eth
    FILES
    IStarknetMessaging.sol
    StarknetMessaging.sol

    LIBS
    named_storage_sol
)
