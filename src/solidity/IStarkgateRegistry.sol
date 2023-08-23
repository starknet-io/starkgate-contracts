// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

interface IStarkgateRegistry {
    /**
      Returns the bridge that handles the given token.
    */
    function getBridge(address tokenAddress) external view returns (address);

    /**
      Add a mapping between a token and the bridge handling it.
    */
    function enrollToken(address tokenAddress, address bridge) external;

    /**
      Deactivates token bridging.
      A deactivated token is blocked for deposits and blocked for re-deployment.
     */
    function deactivateToken(address token) external;

    /**
      Retrieves a list of bridge addresses that have facilitated withdrawals 
      for the specified token.
     */
    function getWithdrawalBridges(address token) external view returns (address[] memory bridges);

    /**
      Allows a bridge remove itself from the registry.
      The calling bridge is required to implement isDepositAllowed(address) returns (bool).
     */
    function removeSelf(address token) external;
}
