// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "src/solidity/StarknetTokenStorage.sol";
import "starkware/solidity/interfaces/ExternalInitializer.sol";
import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/solidity/libraries/RolesLib.sol";
import "src/solidity/WithdrawalLimit.sol";

/*
  This contract is an external initializing contract that
  perform data migration during starkgate bridge upgrade.
*/
contract StarkgateUpgradeAssistExternalInitializer is ExternalInitializer, StarknetTokenStorage {
    event LegacyBridgeUpgraded(address indexed bridge, address indexed token);

    // Legacy named storage slot tags.
    string constant MAX_DEPOSIT_TAG = "STARKNET_TOKEN_BRIDGE_MAX_DEPOSIT";
    string constant MAX_TOTAL_BALANCE_TAG = "STARKNET_TOKEN_BRIDGE_MAX_TOTAL_BALANCE";

    // Legacy getters.
    function getBridgedToken() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGED_TOKEN_TAG);
    }

    function setBridgedToken(address contract_) internal {
        NamedStorage.setAddressValue(BRIDGED_TOKEN_TAG, contract_);
    }

    function getMaxDeposit() internal view returns (uint256) {
        return NamedStorage.getUintValue(MAX_DEPOSIT_TAG);
    }

    function getMaxTotalBalance() internal view returns (uint256) {
        return NamedStorage.getUintValue(MAX_TOTAL_BALANCE_TAG);
    }

    function initialize(bytes calldata data) external virtual override {
        require(data.length == 64, "INVALID_INIT_DATA_LENGTH_64");

        // Initialize roles - Roles.initialize() checks for init mismatch.
        // If a desired governance address passed - use it.
        // Otherwise use msg.sender as an initial governor.
        // If a desired secAdmin address passed - use it.
        // Otherwise used the address used for governor (whether passed or not).
        (address assignedGovernor, address securityAdmin) = abi.decode(data, (address, address));
        assignedGovernor = assignedGovernor == address(0) ? msg.sender : assignedGovernor;
        securityAdmin = securityAdmin == address(0) ? assignedGovernor : securityAdmin;
        RolesLib.initialize(assignedGovernor, securityAdmin);

        // We want to make sure we don't upgrade a new bridge,
        // as it would cause errors.
        // New bridge does not have maxDeposit value.
        // Viable Legacy bridge does. This also blocks a direct call.
        uint256 maxDeposit = getMaxDeposit();
        require(maxDeposit > 0, "NOT_LEGACY_BRIDGE");

        // Read current maxTvl. Adjust value 0 case.
        uint256 maxTotalBalance = getMaxTotalBalance();
        if (maxTotalBalance == 0) {
            maxTotalBalance = 1;
        }

        // Read L1 token address. Adjust Eth case.
        address bridgedToken = getBridgedToken();
        if (bridgedToken == address(0)) {
            bridgedToken = ETH;
            setBridgedToken(ETH);
        }

        // Populate token setting new structure.
        TokenSettings storage settings = tokenSettings()[bridgedToken];

        // Prevent re-do.
        require(settings.tokenStatus == TokenStatus.Unknown, "BRIDGE_ALREADY_UPGRADED");

        settings.tokenStatus = TokenStatus.Active;
        settings.maxTotalBalance = maxTotalBalance;
        WithdrawalLimit.setWithdrawLimitPct(WithdrawalLimit.DEFAULT_WITHDRAW_LIMIT_PCT);
        emit LogExternalInitialize(data);
        emit LegacyBridgeUpgraded(address(this), bridgedToken);
    }
}
