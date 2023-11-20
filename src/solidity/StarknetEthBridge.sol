// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/libraries/Addresses.sol";
import "src/solidity/Fees.sol";
import "src/solidity/StarknetTokenBridge.sol";

contract StarknetEthBridge is StarknetTokenBridge {
    using Addresses for address;
    event LogDeposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce,
        uint256 fee
    );

    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetEthBridge_2.0_2";
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

    function acceptDeposit(
        address, /*token*/
        uint256 amount
    ) internal override returns (uint256) {
        // Make sure msg.value is enough to cover amount. The remaining value is fee.
        require(msg.value >= amount, "INSUFFICIENT_VALUE");
        uint256 fee = msg.value - amount;
        Fees.checkDepositFee(fee);
        // The msg.value was already credited to this contract. Fee will be passed to Starknet.
        require(address(this).balance - fee <= getMaxTotalBalance(ETH), "MAX_BALANCE_EXCEEDED");
        return fee;
    }

    function transferOutFunds(
        address, /*token*/
        uint256 amount,
        address recipient
    ) internal override {
        recipient.performEthTransfer(amount);
    }

    function deposit(uint256 amount, uint256 l2Recipient) external payable {
        uint256[] memory noMessage = new uint256[](0);
        uint256 fee = acceptDeposit(ETH, amount);
        uint256 nonce = sendDepositMessage(
            ETH,
            amount,
            l2Recipient,
            noMessage,
            HANDLE_TOKEN_DEPOSIT_SELECTOR,
            fee
        );
        emitDepositEvent(
            ETH,
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
        return getMaxTotalBalance(ETH);
    }

    function withdraw(uint256 amount, address recipient) external {
        withdraw(ETH, amount, recipient);
    }

    function withdraw(uint256 amount) external {
        withdraw(ETH, amount, msg.sender);
    }
}
