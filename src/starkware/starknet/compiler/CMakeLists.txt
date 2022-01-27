python_venv(starknet_compile_venv
    PYTHON python3.7

    LIBS
    pip_cairo_lang
)

python_exe(starknet_compile_exe
    VENV starknet_compile_venv
    MODULE starkware.starknet.compiler.compile
)
