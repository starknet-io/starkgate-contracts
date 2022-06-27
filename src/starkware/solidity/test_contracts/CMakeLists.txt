python_lib(test_erc20_sol
    PREFIX starkware/solidity/test_contracts
    FILES
    TestERC20.sol

    LIBS
    erc20_sol
)

solidity_env(test_erc20_sol_env
    CONTRACTS
    TestERC20

    LIBS
    test_erc20_sol
)

python_lib(starkware_contracts_test_contracts_lib
    PREFIX starkware/solidity/test_contracts
    FILES
    contracts.py

    LIBS
    starkware_contracts_utils_lib

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/TestERC20.json TestERC20.json"
)
add_dependencies(starkware_contracts_test_contracts_lib test_erc20_sol_env)
