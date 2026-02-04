// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "src/solidity/StarknetTokenBridge.sol";
import "starkware/solidity/components/OverrideLegacyProxyGovernance.sol";
import "starkware/solidity/libraries/NamedStorage.sol";

/*
  Common implementation for the Upgraded legacy bridges, contains all the legacy relevant
  code except for the handling of Eth transfers (vs. ERC20).
*/
abstract contract LegacyBridge is StarknetTokenBridge, OverrideLegacyProxyGovernance {
    /* Legacy events */
    event LogDepositCancelRequest(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce
    );
    event LogDepositReclaimed(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce
    );
    event LogDeposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce,
        uint256 fee
    );

    function bridgedToken() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGED_TOKEN_TAG);
    }

    function depositors() internal pure returns (mapping(uint256 => address) storage) {
        return NamedStorage.uintToAddressMapping(DEPOSITOR_ADDRESSES_TAG);
    }

    modifier onlyDepositor(uint256 nonce) {
        require(depositors()[nonce] == msg.sender, "ONLY_DEPOSITOR");
        _;
    }

    /*
      Upgraded legacy bridge does not support token enrollment.
    */
    function enrollToken(
        address /*token*/
    ) external payable virtual override {
        revert("UNSUPPORTED");
    }

    /// Support Legacy ABI.
    /*
      Deposit, using the old version ABI.
      Note - The actual L1-L2 message sent to the l2-bridge is of the new format.
    */
    function deposit(uint256 amount, uint256 l2Recipient) external payable {
        uint256[] memory noMessage = new uint256[](0);
        address token = bridgedToken();
        uint256 fee = acceptDeposit(token, amount);
        uint256 nonce = sendDepositMessage(
            token,
            amount,
            l2Recipient,
            noMessage,
            HANDLE_TOKEN_DEPOSIT_SELECTOR,
            fee
        );
        emitDepositEvent(
            token,
            amount,
            l2Recipient,
            noMessage,
            HANDLE_TOKEN_DEPOSIT_SELECTOR,
            nonce,
            fee
        );
        // Emits a deposit event of the old ABI, emitted in addition to the new one.
        emit LogDeposit(msg.sender, amount, l2Recipient, nonce, fee);
    }

    function maxTotalBalance() external view returns (uint256) {
        return getMaxTotalBalance(bridgedToken());
    }

    function withdraw(uint256 amount, address recipient) external {
        withdraw(bridgedToken(), amount, recipient);
    }

    function withdraw(uint256 amount) external {
        withdraw(bridgedToken(), amount, msg.sender);
    }

    /*
      This comsume message override the base implementation from StarknetTokenBridge,
      and supports withdraw of both the new format and the legacy format.
    */
    function consumeMessage(
        address token,
        uint256 amount,
        address recipient
    ) internal virtual override {
        require(l2TokenBridge() != 0, "L2_BRIDGE_NOT_SET");
        uint256 u_recipient = uint256(uint160(recipient));
        uint256 amount_low = amount & (UINT256_PART_SIZE - 1);
        uint256 amount_high = amount >> UINT256_PART_SIZE_BITS;

        // Compose the new format of L2-L1 consumption.
        uint256[] memory payload = new uint256[](5);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = u_recipient;
        payload[2] = uint256(uint160(token));
        payload[3] = amount_low;
        payload[4] = amount_high;
        // Contain failure of comsumption (e.g. no message to consume).
        try messagingContract().consumeMessageFromL2(l2TokenBridge(), payload) {} catch Error(
            string memory
        ) {
            // Upon failure with the new format,
            // compose the old format,
            // in case the withdrawal was initiated on a bridge with an older version.
            payload = new uint256[](4);
            payload[0] = TRANSFER_FROM_STARKNET;
            payload[1] = u_recipient;
            payload[2] = amount_low;
            payload[3] = amount_high;
            messagingContract().consumeMessageFromL2(l2TokenBridge(), payload);

            // The old msg format is valid only for the legacy bridged token.
            // Since the withdraw flow can be token-explicit with any token,
            // we must enforce that the token is identical to the legacy token.
            require(bridgedToken() == token, "NOT_LEGACY_BRIDGED_TOKEN");
        }
    }

    // The old version of depositCancelRequest (renamed to avoid confusion).
    // Supports cancellation of deposits that were made before the L1 bridge was upgraded.
    function legacyDepositCancelRequest(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            legacyDepositMessagePayload(amount, l2Recipient),
            nonce
        );
        emit LogDepositCancelRequest(msg.sender, amount, l2Recipient, nonce);
    }

    // The old version of depositReclaim (renamed to avoid confusion).
    // Supports reclaim of deposits that were made before the L1 bridge was upgraded.
    function legacyDepositReclaim(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            legacyDepositMessagePayload(amount, l2Recipient),
            nonce
        );

        transferOutFunds(bridgedToken(), amount, msg.sender);
        emit LogDepositReclaimed(msg.sender, amount, l2Recipient, nonce);
    }

    // Construct the deposit l1-l2 message payload of the older version.
    // (renamed to avoid confusion).
    function legacyDepositMessagePayload(uint256 amount, uint256 l2Recipient)
        private
        pure
        returns (uint256[] memory)
    {
        uint256[] memory payload = new uint256[](3);
        payload[0] = l2Recipient;
        payload[1] = amount & (UINT256_PART_SIZE - 1);
        payload[2] = amount >> UINT256_PART_SIZE_BITS;
        return payload;
    }
}
