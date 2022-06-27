python_lib(proxy_contract_sol
    PREFIX starkware/solidity/upgrade
    FILES
    Proxy.sol
    ProxyGovernance.sol
    ProxyStorage.sol
    StorageSlots.sol

    LIBS
    common_library_sol
    governance_contract_sol
    solidity_contracts_interfaces_sol
)

solidity_env(proxy_contract_sol_env
    CONTRACTS
    Proxy

    LIBS
    proxy_contract_sol
)

python_lib(proxy_contract_lib
    PREFIX starkware/solidity/upgrade
    FILES
    contracts.py

    LIBS
    starkware_contracts_utils_lib

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/Proxy.json Proxy.json"
)
add_dependencies(proxy_contract_lib proxy_contract_sol_env)
