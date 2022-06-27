if (NOT DEFINED STARKGATE_ETH_ADDITIONAL_LIBS)
    set(STARKGATE_ETH_ADDITIONAL_LIBS pip_cairo_lang)
endif()
if (NOT DEFINED STARKGATE_CAIRO_ADDITIONAL_LIBS)
    set(STARKGATE_CAIRO_ADDITIONAL_LIBS pip_cairo_lang)
endif()

add_subdirectory(cairo)
add_subdirectory(eth)

python_lib(starkgate_conftest_lib
    PREFIX starkware/starknet/apps/starkgate

    FILES
    conftest.py

    LIBS
    proxy_contract_lib
    starkware_contracts_test_contracts_lib
    starkgate_eth_contracts_lib
    starkgate_eth_test_contracts_lib
    starknet_test_utils
    ${STARKGATE_ETH_ADDITIONAL_LIBS}
    pip_pytest
)

full_python_test(starkgate_flow_test
    PREFIX starkware/starknet/apps/starkgate
    PYTHON ${PYTHON_COMMAND}
    TESTED_MODULES starkware/starknet/apps/starkgate

    FILES
    flow_test.py

    LIBS
    cairo_erc20_contract_lib
    starkgate_cairo_contracts_lib
    starkgate_conftest_lib
    starknet_proxy_contract_lib
    starknet_upgradability_test_utils_lib
    ${STARKGATE_ETH_ADDITIONAL_LIBS}
    ${STARKGATE_CAIRO_ADDITIONAL_LIBS}
    pip_pytest
    pip_pytest_asyncio
)

python_lib(copy_starkgate_artifacts_lib
    PREFIX starkware/starknet/apps/starkgate

    FILES copy_starkgate_artifacts.py

    LIBS
    cairo_erc20_contract_lib
    starkgate_cairo_contracts_lib
    starkgate_eth_contracts_lib
    ${STARKGATE_CAIRO_ADDITIONAL_LIBS}
    ${STARKGATE_ETH_ADDITIONAL_LIBS}
    starkware_contracts_utils_lib
)

python_venv(copy_starkgate_artifacts_venv
    PYTHON ${PYTHON_COMMAND}
    LIBS
    copy_starkgate_artifacts_lib
)

python_exe(copy_starkgate_artifacts
    VENV copy_starkgate_artifacts_venv
    MODULE starkware.starknet.apps.starkgate.copy_starkgate_artifacts
)

set(ARTIFACTS_DIR "${CMAKE_CURRENT_BINARY_DIR}/artifacts")
set(ARTIFACTS_STAMP "${ARTIFACTS_DIR}/starkgate.stamp")

set(SOLIDITY_BRIDGE_ARTIFACTS_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/eth/starkgate_bridge_sol_env/artifacts")
set(CAIRO_BRIDGE_ARTIFACTS_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/cairo/")
set(CAIRO_ERC20_ARTIFACTS_BUILD_DIR "${CMAKE_BINARY_DIR}/src/starkware/starknet/std_contracts/ERC20/")

add_custom_command(
    OUTPUT ${ARTIFACTS_STAMP}
    COMMENT "Copying cairo and solidity compiled contracts to ${ARTIFACTS_DIR}"
    # Erasing old artifacts so that if the version has changed they will be replaced.
    COMMAND rm -f ${ARTIFACTS_DIR}/**.json
    COMMAND ${CMAKE_CURRENT_BINARY_DIR}/copy_starkgate_artifacts
        --solidity_bridge_artifacts_dir ${SOLIDITY_BRIDGE_ARTIFACTS_BUILD_DIR}
        --cairo_bridge_artifacts_dir ${CAIRO_BRIDGE_ARTIFACTS_BUILD_DIR}
        --cairo_erc20_artifacts_dir ${CAIRO_ERC20_ARTIFACTS_BUILD_DIR} 
        --output_dir ${ARTIFACTS_DIR}
    COMMAND touch ${ARTIFACTS_STAMP}
    DEPENDS copy_starkgate_artifacts ${CMAKE_CURRENT_BINARY_DIR}/copy_starkgate_artifacts
)
add_custom_target(starkgate_artifacts ALL DEPENDS ${ARTIFACTS_STAMP})
