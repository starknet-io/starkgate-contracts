// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

interface IStarkgateBridge {
    /**
       Enrolls a token in the Starknet Token Bridge system.
    */
    function enrollToken(address token) external payable;

    /**
      Deactivates token bridging.
      Deactivated token does not accept deposits.
     */
    function deactivate(address token) external;
}
