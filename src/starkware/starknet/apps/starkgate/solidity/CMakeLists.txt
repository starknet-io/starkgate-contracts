python_lib(starkgate_bridge_sol
    PREFIX starkware/starknet/apps/starkgate/solidity
    FILES
    StarknetERC20Bridge.sol
    StarknetEthBridge.sol
    StarknetTokenBridge.sol
    StarknetTokenStorage.sol
    Transfers.sol

    LIBS
    cairo_sol
    ierc20_sol
    named_storage_sol
    proxy_contract_sol
    solidity_contract_initializer_sol
    starknet_governance_sol
    starknet_messaging_sol
)

solidity_env(starkgate_bridge_sol_env
    CONTRACTS
    StarknetERC20Bridge
    StarknetEthBridge
    LIBS
    starkgate_bridge_sol
)

python_lib(starkgate_solidity_contracts_lib
    PREFIX starkware/starknet/apps/starkgate/solidity
    FILES
    contracts.py

    LIBS
    starkware_contracts_utils_lib

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetERC20Bridge.json StarknetERC20Bridge.json"
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetEthBridge.json StarknetEthBridge.json"
)
add_dependencies(starkgate_solidity_contracts_lib starkgate_bridge_sol_env)
