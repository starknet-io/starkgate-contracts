// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

interface IStarkgateManager {
    /**
      Returns the address of the Starkgate Registry contract.
    */
    function getRegistry() external view returns (address);

    // TODO: refactor the doc.
    /**
      Adds an existing bridge to the Starkgate system for a specific token.
     */
    function addExistingBridge(address token, address bridge) external;

    /**
      Deactivates bridging of a specific token.
      A deactivated token is blocked for deposits and cannot be re-deployed.     
      */
    function deactivateToken(address token) external;

    /**
      Block a specific token from being used in the StarkGate.
      A blocked token cannot be deployed.
      */
    function blockToken(address token) external;

    /**
      Enrolls a token bridge for a specific token.
     */
    function enrollTokenBridge(address token) external payable;
}
