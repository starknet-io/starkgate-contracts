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
  initialize StarknetEthBridge/StarknetERC20Bridge/StarknetTokenBridge as a single bridge,
  assuming they are freshly deployed and NOT upgrading a legacy bridge.
*/
contract ConfigureSingleBridgeEIC is ExternalInitializer, StarknetTokenStorage {
    event SingleBridgeInit(
        address messagingContract,
        address l1Bridge,
        uint256 l2Bridge,
        address token
    );

    // Legacy getters.
    function getBridgedToken() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGED_TOKEN_TAG);
    }

    function setBridgedToken(address contract_) internal {
        NamedStorage.setAddressValue(BRIDGED_TOKEN_TAG, contract_);
    }

    function initialize(bytes calldata data) external virtual override {
        require(data.length == 96, "INVALID_INIT_DATA_LENGTH_96");

        // We expected data to include 96 bytes, with concatanated addresses as following:
        // bytes 00-31 massagingContract (L1 SN Core contract address)
        // bytes 32-63 Bridged L1 token address.
        // bytes 64-95 L2 Bridge (optional. this can be set later as well.)
        // Note - in case of Eth bridge Either 0 or ETH L1-Label can be used.
        (address messagingContract_, address l1Token_, uint256 l2Bridge_) = abi.decode(
            data,
            (address, address, uint256)
        );

        // This will initialize governance to msg.sender.
        // It wil fail if already initialized differently.
        RolesLib.initialize();

        // Resetting messagingContract will fail, no need to check here.
        // This ensures that this code can run only on a fresh deployment.
        messagingContract(messagingContract_);
        l2TokenBridge(l2Bridge_);
        if (l1Token_ == address(0)) {
            l1Token_ = ETH;
        }
        setBridgedToken(l1Token_);

        // Populate token setting new structure.
        TokenSettings storage settings = tokenSettings()[l1Token_];

        settings.tokenStatus = TokenStatus.Active;
        WithdrawalLimit.setWithdrawLimitPct(WithdrawalLimit.DEFAULT_WITHDRAW_LIMIT_PCT);
        emit LogExternalInitialize(data);
        emit SingleBridgeInit(messagingContract_, address(this), l2Bridge_, l1Token_);
    }
}
