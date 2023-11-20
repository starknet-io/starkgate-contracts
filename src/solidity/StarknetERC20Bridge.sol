// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/Addresses.sol";
import "src/solidity/StarknetTokenBridge.sol";

import "starkware/solidity/libraries/NamedStorage.sol";

contract StarknetERC20Bridge is StarknetTokenBridge {
    using Addresses for address;
    event LogDeposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce,
        uint256 fee
    );

    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetERC20Bridge_2.0_2";
    }

    function enrollToken(
        address /*token*/
    ) external payable virtual override {
        revert("UNSUPPORTED");
    }

    function consumeMessage(
        address token,
        uint256 amount,
        address recipient
    ) internal virtual override {
        require(l2TokenBridge() != 0, "L2_BRIDGE_NOT_SET");
        uint256 u_recepient = uint256(uint160(recipient));
        uint256 amount_low = amount & (UINT256_PART_SIZE - 1);
        uint256 amount_high = amount >> UINT256_PART_SIZE_BITS;

        uint256[] memory payload = new uint256[](5);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = u_recepient;
        payload[2] = uint256(uint160(token));
        payload[3] = amount_low;
        payload[4] = amount_high;
        try messagingContract().consumeMessageFromL2(l2TokenBridge(), payload) {} catch Error(
            string memory
        ) {
            // For backwards compatibility with older versions of the bridge.
            payload = new uint256[](4);
            payload[0] = TRANSFER_FROM_STARKNET;
            payload[1] = u_recepient;
            payload[2] = amount_low;
            payload[3] = amount_high;
            messagingContract().consumeMessageFromL2(l2TokenBridge(), payload);
        }
    }

    string internal constant BRIDGED_TOKEN_TAG = "STARKNET_ERC20_TOKEN_BRIDGE_TOKEN_ADDRESS";

    function bridgedToken() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGED_TOKEN_TAG);
    }

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
}
