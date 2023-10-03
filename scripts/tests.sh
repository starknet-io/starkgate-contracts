#!/bin/bash
pushd $(dirname "$0")/..

COLOR_OFF="\033[0m"
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'


printf "${YELLOW}Check cairo format...\n"
scripts/cairo-format.py src/cairo -cr
if [ $? -eq 0 ]; then
    printf "${GREEN}Check cairo format succeed\n"
else
    printf "${RED}Check cairo format failed\n${PURPLE}Run 'scripts/cairo-format.py src/cairo -r' to fix.\n"
    exit 1
fi


printf "${YELLOW}Check Line Length...\n"
scripts/line_length.py
if  [ $? -ne 0 ]; then
    exit 1
fi


printf "${YELLOW}Run black...\n"
black  -l 100 --diff --check --color --diff .
if [ $? -eq 0 ]; then
    printf "${GREEN}Run black succeed\n"
else
    printf "${RED}Run black failed\n${PURPLE}Run 'black -l 100 .' to solve this problem.\n"
    exit 1
fi

printf "${YELLOW}Run cairo test...\n"
scripts/cairo-test.py --starknet src/
if [ $? -eq 0 ]; then
    printf "${GREEN}Run cairo succeed\n"
else
    printf "${RED}Run cairo test failed.\n"
    exit 1
fi

printf "${YELLOW}Run prettier for Solidity...\n"
scripts/run_prettier.py
if [ $? -eq 1 ]; then
    printf "${RED}Run prettier for Solidity failed\n${PURPLE}Run scripts/run_prettier.py --fix' to fix\n"
    exit 1
fi

printf "${YELLOW}Compile Solidity...\n"
scripts/build-solidity.sh
if [ $? -eq 0 ]; then
    printf "${GREEN}Compile Solidity succeed\n"
else
    printf "${RED}Compile Solidity failed.\n"
    exit 1
fi


printf "${YELLOW}Pytest...\n"
pytest src/solidity -sv
if [ $? -eq 0 ]; then
    printf "${GREEN}Pytest succeed\n"
else
    printf "${RED}Pytest failed.\n"
    exit 1
fi

# Reset
printf "${COLOR_OFF}"

popd
