if (NOT DEFINED CAIRO_ERC20_ADDITIONAL_LIBS)
    set(CAIRO_ERC20_ADDITIONAL_LIBS pip_cairo_lang)
endif()

starknet_compile(compile_erc20_contract ERC20.json ERC20.cairo "")

python_lib(cairo_erc20_contract_lib
    PREFIX starkware/starknet/std_contracts/ERC20

    FILES
    contracts.py

    LIBS
    ${CAIRO_ERC20_ADDITIONAL_LIBS}

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/ERC20.json ERC20.json"
)
add_dependencies(cairo_erc20_contract_lib
    compile_erc20_contract
)

full_python_test(cairo_erc20_test
    NO_CODE_COVERAGE
    PREFIX starkware/starknet/std_contracts/ERC20
    PYTHON ${PYTHON_COMMAND}
    TESTED_MODULES starkware/starknet/std_contracts/ERC20

    FILES
    ERC20_test.py

    LIBS
    cairo_erc20_contract_lib
    ${CAIRO_ERC20_ADDITIONAL_LIBS}
    starknet_proxy_contract_lib
    starknet_test_utils
    starknet_upgradability_test_utils_lib
    pip_pytest
    pip_pytest_asyncio
)
