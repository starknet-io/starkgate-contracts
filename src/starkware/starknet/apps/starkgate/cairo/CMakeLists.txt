starknet_compile(compile_erc20_contract ERC20.json ERC20.cairo "")
starknet_compile(compile_token_bridge_contract token_bridge.json token_bridge.cairo "")

python_lib(starkgate_cairo_contracts_lib
    PREFIX starkware/starknet/apps/starkgate/cairo

    FILES
    contracts.py

    LIBS
    ${STARKNET_LIBS}

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/ERC20.json ERC20.json"
    "${CMAKE_CURRENT_BINARY_DIR}/token_bridge.json token_bridge.json"
)
add_dependencies(starkgate_cairo_contracts_lib
    compile_erc20_contract
    compile_token_bridge_contract
)

full_python_test(starkgate_cairo_test
    PREFIX starkware/starknet/apps/starkgate/cairo
    PYTHON python3.7
    TESTED_MODULES starkware/starknet/apps/starkgate/cairo

    FILES
    token_test.py
    bridge_test.py

    LIBS
    starkgate_cairo_contracts_lib
    starkgate_conftest_lib
    ${STARKNET_LIBS}
    pip_pytest
    pip_pytest_asyncio
)
