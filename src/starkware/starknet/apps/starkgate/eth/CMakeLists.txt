python_lib(starkgate_bridge_sol
    PREFIX starkware/starknet/apps/starkgate/eth
    FILES
    StarknetERC20Bridge.sol
    StarknetEthBridge.sol
    StarknetBridgeConstatns.sol
    StarknetTokenBridge.sol
    StarknetTokenStorage.sol
    Transfers.sol

    LIBS
    cairo_sol
    erc20_sol
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

python_lib(starkgate_eth_contracts_lib
    PREFIX starkware/starknet/apps/starkgate/eth
    FILES
    contracts.py

    LIBS
    starkware_contracts_utils_lib

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetERC20Bridge.json StarknetERC20Bridge.json"
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetEthBridge.json StarknetEthBridge.json"
)
add_dependencies(starkgate_eth_contracts_lib starkgate_bridge_sol_env)

python_lib(starkgate_bridge_tester_sol
    PREFIX starkware/starknet/apps/starkgate/eth
    FILES
    StarknetEthBridgeTester.sol
    StarknetERC20BridgeTester.sol

    LIBS
    starkgate_bridge_sol
)

solidity_env(starkgate_bridge_tester_sol_env
    CONTRACTS
    StarknetERC20BridgeTester
    StarknetEthBridgeTester
    LIBS
    starkgate_bridge_tester_sol
)

python_lib(starkgate_eth_test_contracts_lib
    PREFIX starkware/starknet/apps/starkgate/eth
    FILES
    test_contracts.py

    LIBS
    starkware_contracts_utils_lib

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetERC20BridgeTester.json StarknetERC20BridgeTester.json"
    "${CMAKE_CURRENT_BINARY_DIR}/StarknetEthBridgeTester.json StarknetEthBridgeTester.json"
)
add_dependencies(starkgate_eth_test_contracts_lib starkgate_bridge_tester_sol_env)

full_python_test(starkgate_eth_test
    PREFIX starkware/starknet/apps/starkgate/eth
    PYTHON ${PYTHON_COMMAND}
    TESTED_MODULES starkware/starknet/apps/starkgate/eth

    FILES
    token_bridge_test.py
    token_bridge_storage_test.py

    LIBS
    starkgate_bridge_tester_sol
    starkgate_conftest_lib
    ${STARKGATE_ETH_ADDITIONAL_LIBS}
    pip_pytest
    pip_pytest_asyncio
)
