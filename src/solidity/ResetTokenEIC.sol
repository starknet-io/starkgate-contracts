// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "src/solidity/StarknetTokenStorage.sol";
import "starkware/solidity/interfaces/ExternalInitializer.sol";
import "starkware/solidity/libraries/NamedStorage.sol";

/*
  This contract is an external initializing contract that
  resets token status on the starkgate bridge.
*/
contract ResetTokenEIC is ExternalInitializer, StarknetTokenStorage {
    event TokenReset(address indexed token);

    function initialize(bytes calldata data) external virtual override {
        require(data.length == 32, "INVALID_INIT_DATA_LENGTH_32");
        address token = abi.decode(data, (address));
        TokenSettings storage settings = tokenSettings()[token];

        // Don't reset an active token.
        require(settings.tokenStatus != TokenStatus.Active, "CANNOT_RESET_ACTIVE_TOKEN");
        settings.tokenStatus = TokenStatus.Unknown;

        emit LogExternalInitialize(data);
        emit TokenReset(token);
    }
}
