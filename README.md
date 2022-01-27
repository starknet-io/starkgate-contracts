# Starkgate - StarkNet L1 Bridges

## Overview

This repository contains the Cairo and Solidity code for the L1<>L2 bridges of StarkNet,
as well as StarkNet's ERC20 token contract implementation that interacts with the bridges.
You can read the documentation of the bridges [here](https://starknet.io/documentation/starkgate-token-bridge/)
and the documentation of the general L1<>StarkNet messaging system [here](https://starknet.io/documentation/l1-l2-messaging/).

You can find the L1 addresses and L2 addresses for the deployed bridges on StarkNet Alpha on Goerli and on Mainnet [here](https://github.com/starkware-libs/starknet-addresses).

Note: The frontend of the bridges, can be found [here](https://github.com/starkware-libs/starkgate-frontend).

If you are not familiar with Cairo, you can find more details about it [here](https://www.cairo-lang.org/).

## Main module

**src/starkware/starknet/apps/starkgate**:
The Cairo and Solidity contracts of the bridge, StarkNet's ERC20 token contract and corresponding tests.

## Running the tests

The root directory holds a dedicated Dockerfile, which automatically builds the project and runs
the unit tests.
You should have docker installed (see https://docs.docker.com/get-docker/).

Build the docker image:

```bash
> docker build --tag starkgate .
```

Alternatively, you can build the project and run the tests:
```bash
> ./build.sh
> cd build/Release
> ctest -V
```
