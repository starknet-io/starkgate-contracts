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
    function enlistToken(address tokenAddress, address bridge) external;

    /**
      Deactivates bridging of a specific token.
      A deactivated token is blocked for deposits and blocked for re-deployment.
     */
    function deactivateToken(address token) external;

    /**
      Block a specific token from being used in the StarkGate.
      A blocked token cannot be deployed.
      */
    function blockToken(address token) external;

    /**
      Retrieves a list of bridge addresses that have facilitated withdrawals 
      for the specified token.
     */
    function getWithdrawalBridges(address token) external view returns (address[] memory bridges);

    /**
      Using this function a bridge removes enlisting of its token from the registry.
      The bridge must implement `isServicingToken(address token)` (see `IStarkgateService`).
     */
    function selfRemove(address token) external;
}
