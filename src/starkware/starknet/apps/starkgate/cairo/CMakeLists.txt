starknet_compile(compile_token_bridge_contract token_bridge.json token_bridge.cairo "")

python_lib(starkgate_cairo_contracts_lib
    PREFIX starkware/starknet/apps/starkgate/cairo

    FILES
    contracts.py

    LIBS
    ${STARKGATE_CAIRO_ADDITIONAL_LIBS}

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/token_bridge.json token_bridge.json"
)
add_dependencies(starkgate_cairo_contracts_lib
    compile_token_bridge_contract
)

full_python_test(starkgate_cairo_test
    PREFIX starkware/starknet/apps/starkgate/cairo
    PYTHON ${PYTHON_COMMAND}
    TESTED_MODULES starkware/starknet/apps/starkgate/cairo

    FILES
    bridge_test.py

    LIBS
    cairo_erc20_contract_lib
    starkgate_cairo_contracts_lib
    starkgate_conftest_lib
    starknet_proxy_contract_lib
    starknet_upgradability_test_utils_lib
    ${STARKGATE_CAIRO_ADDITIONAL_LIBS}
    pip_pytest
    pip_pytest_asyncio
)
