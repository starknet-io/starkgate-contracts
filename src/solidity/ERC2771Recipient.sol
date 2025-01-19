// SPDX-License-Identifier: MIT
// solhint-disable no-inline-assembly
pragma solidity >=0.6.9;

import "starkware/solidity/libraries/NamedStorage.sol";
import "./IERC2771Recipient.sol";

/**
 * @title The ERC-2771 Recipient Base Abstract Class - Implementation
 *
 * @notice Note that this contract was called `BaseRelayRecipient` in the previous revision of the GSN.
 *
 * @notice A base contract to be inherited by any contract that want to receive relayed transactions.
 *
 * @notice A subclass must use `_msgSender()` instead of `msg.sender`.
 */
abstract contract ERC2771Recipient is IERC2771Recipient {
    /*
     * Forwarder singleton we accept calls from
     */
    string internal constant TRUSTED_FORWARDER_TAG = "STARKNET_TOKEN_BRIDGE_TRUSTED_FORWARDER_TAG";

    /**
     * :warning: **Warning** :warning: The Forwarder can have a full control over your Recipient. Only trust verified Forwarder.
     * @notice Method is not a required method to allow Recipients to trust multiple Forwarders. Not recommended yet.
     * @return forwarder The address of the Forwarder contract that is being used.
     */
    function getTrustedForwarder() public view virtual returns (address forwarder) {
        return NamedStorage.getAddressValue(TRUSTED_FORWARDER_TAG);
    }

    function _setTrustedForwarder(address _forwarder) internal {
        NamedStorage.setAddressValueOnce(TRUSTED_FORWARDER_TAG, _forwarder);
    }

    /// @inheritdoc IERC2771Recipient
    function isTrustedForwarder(address forwarder) public view virtual override returns (bool) {
        return forwarder == NamedStorage.getAddressValue(TRUSTED_FORWARDER_TAG);
    }

    /// @inheritdoc IERC2771Recipient
    function _msgSender() internal view virtual override returns (address ret) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            ret = msg.sender;
        }
    }

    /// @inheritdoc IERC2771Recipient
    function _msgData() internal view virtual override returns (bytes calldata ret) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            return msg.data[0:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}
