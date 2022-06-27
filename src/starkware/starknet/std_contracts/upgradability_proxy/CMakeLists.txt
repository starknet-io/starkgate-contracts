if (NOT DEFINED UPGRADABILITY_PROXY_ADDITIONAL_LIBS)
    set(UPGRADABILITY_PROXY_ADDITIONAL_LIBS pip_cairo_lang)
endif()

starknet_compile(compile_governance_contract governance.json governance.cairo "")
starknet_compile(compile_proxy_contract proxy.json proxy.cairo "")

python_lib(starknet_proxy_contract_lib
    PREFIX starkware/starknet/std_contracts/upgradability_proxy

    FILES
    contracts.py

    LIBS
    ${UPGRADABILITY_PROXY_ADDITIONAL_LIBS}

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/governance.json governance.json"
    "${CMAKE_CURRENT_BINARY_DIR}/proxy.json proxy.json"
)
add_dependencies(starknet_proxy_contract_lib
    compile_governance_contract
    compile_proxy_contract
)

starknet_compile(compile_impl_contract_a impl_contract_a.json impl_contract_a.cairo "")
starknet_compile(compile_impl_contract_b impl_contract_b.json impl_contract_b.cairo "")
starknet_compile(compile_test_eic test_eic.json test_eic.cairo "")

python_lib(starknet_proxy_test_contract_lib
    PREFIX starkware/starknet/std_contracts/upgradability_proxy

    FILES
    test_contracts.py

    LIBS
    ${UPGRADABILITY_PROXY_ADDITIONAL_LIBS}

    ARTIFACTS
    "${CMAKE_CURRENT_BINARY_DIR}/impl_contract_a.json impl_contract_a.json"
    "${CMAKE_CURRENT_BINARY_DIR}/impl_contract_b.json impl_contract_b.json"
    "${CMAKE_CURRENT_BINARY_DIR}/test_eic.json test_eic.json"
)
add_dependencies(starknet_proxy_test_contract_lib
    compile_impl_contract_a
    compile_impl_contract_b
    compile_test_eic
)

python_lib(starknet_upgradability_test_utils_lib
    PREFIX starkware/starknet/std_contracts/upgradability_proxy

    FILES
    test_utils.py

    LIBS
    ${UPGRADABILITY_PROXY_ADDITIONAL_LIBS}
)

full_python_test(starknet_upgradability_proxy_test
    NO_CODE_COVERAGE
    PREFIX starkware/starknet/std_contracts/upgradability_proxy
    PYTHON ${PYTHON_COMMAND}
    TESTED_MODULES starkware/starknet/std_contracts/upgradability_proxy

    FILES
    governance_test.py
    upgradability_proxy_test.py

    LIBS
    starknet_proxy_contract_lib
    starknet_proxy_test_contract_lib
    starknet_upgradability_test_utils_lib
    ${UPGRADABILITY_PROXY_ADDITIONAL_LIBS}
    pip_pytest
    pip_pytest_asyncio
)
