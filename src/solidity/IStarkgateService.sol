// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

interface IStarkgateService {
    /**
    Checks whether the calling contract is providing a service for the specified token.
    Returns True if the calling contract is providing a service for the token, otherwise false.
   */
    function isServicingToken(address token) external view returns (bool);
}
