set(STARKNET_LIBS pip_cairo_lang)

add_subdirectory(cairo)
add_subdirectory(solidity)

python_lib(starkgate_conftest_lib
    PREFIX starkware/starknet/apps/starkgate

    FILES
    conftest.py

    LIBS
    pip_pytest
)

set(ARTIFACTS_DIR "${CMAKE_CURRENT_BINARY_DIR}/artifacts")
set(ARTIFACTS_LIST
    ${ARTIFACTS_DIR}/StarknetEthBridge.json
    ${ARTIFACTS_DIR}/StarknetERC20Bridge.json
    ${ARTIFACTS_DIR}/ERC20.json
    ${ARTIFACTS_DIR}/token_bridge.json
)
set(SOLIDITY_ARTIFACTS_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/solidity/starkgate_bridge_sol_env/artifacts")
set(CAIRO_ARTIFACTS_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/cairo/")

add_custom_command(
    OUTPUT ${ARTIFACTS_LIST}
    COMMENT "Copying cairo and solidity compiled contracts to ${ARTIFACTS_DIR}"
    COMMAND mkdir -p ${ARTIFACTS_DIR}/cairo
    COMMAND mkdir -p ${ARTIFACTS_DIR}/solidity
    COMMAND cp -f ${SOLIDITY_ARTIFACTS_BUILD_DIR}/StarknetEthBridge.json ${ARTIFACTS_DIR}/solidity
    COMMAND cp -f ${SOLIDITY_ARTIFACTS_BUILD_DIR}/StarknetERC20Bridge.json ${ARTIFACTS_DIR}/solidity
    COMMAND cp -f ${CAIRO_ARTIFACTS_BUILD_DIR}/ERC20.json ${ARTIFACTS_DIR}/cairo
    COMMAND cp -f ${CAIRO_ARTIFACTS_BUILD_DIR}/token_bridge.json ${ARTIFACTS_DIR}/cairo
    DEPENDS starkgate_bridge_sol_env starkgate_cairo_contracts_lib
)
add_custom_target(starkgate_artifacts ALL DEPENDS ${ARTIFACTS_LIST})
