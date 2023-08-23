// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

interface IStarkgateBridge {
    /**
      Deploys a bridge for the specified token address.
    */
    function deployBridge(address tokenAddress) external;
}
