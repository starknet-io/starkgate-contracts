#!/bin/bash
pushd $(dirname $0)/..

COLOR_OFF="\033[0m"
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'
GANACHE_VERSION="7.9.0"

printf "${YELLOW}Install ganache if there is no installed ganache...\n${COLOR_OFF}"
npm list -g | grep ganache || npm install -g --unsafe-perm ganache@${GANACHE_VERSION}

printf "${YELLOW}Install prettier@2.3.2 if it is no installed...\n${COLOR_OFF}"
npm list -g | grep prettier@2.3.2 || npm install -g prettier@2.3.2

printf "${YELLOW}Install prettier-plugin-solidity@1.0.0-beta.17 if it is no installed...\n${COLOR_OFF}"
npm list -g | grep prettier-plugin-solidity@1.0.0-beta.17 || npm install -g prettier-plugin-solidity@1.0.0-beta.17

printf "${YELLOW}Check ganache version...\n"
npm list -g | grep ganache@${GANACHE_VERSION}
if [ $? -eq 1 ]; then
    printf "${RED}You have an incorrect ganache version!\n"
    printf "${PURPLE}Run:\n    'npm install -g --unsafe-perm ganache@${GANACHE_VERSION}'\nto fix.\n"
    exit 1
fi

printf "${COLOR_OFF}"

mkdir -p .downloads
cd .downloads

if [ "$(uname)" == "Darwin" ]; then
    # Do something under Mac OS X platform        
    wget -c https://github.com/starkware-libs/cairo/releases/download/v2.10.0-rc.0/release-aarch64-apple-darwin.tar -O - | tar -xz
    curl https://binaries.soliditylang.org/linux-amd64/solc-macos-amd64-v0.8.20+commit.a1b79de6 -o solc-0.8.20 && chmod +x solc-0.8.20
else
    wget -c https://github.com/starkware-libs/cairo/releases/download/v2.10.0-rc.0/release-x86_64-unknown-linux-musl.tar.gz -O - | tar -xz
    curl https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.20+commit.a1b79de6 -o solc-0.8.20 && chmod +x solc-0.8.20
fi

cd ..
rm -rf starkware
tar xvf .dep/starkware-solidity-dependencies.tar

popd
