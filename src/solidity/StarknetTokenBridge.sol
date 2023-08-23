// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/cairo/eth/CairoConstants.sol";
import "src/solidity/StarkgateConstants.sol";
import "src/solidity/StarknetTokenStorage.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";

import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/solidity/libraries/Transfers.sol";
import "starkware/solidity/tokens/ERC20/IERC20.sol";

contract StarknetTokenBridge is
    Identity,
    StarknetTokenStorage,
    StarknetBridgeConstants,
    ProxySupport
{
    using Addresses for address;
    event DepositWithMessage(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce,
        uint256 fee
    );
    event DepositWithMessageCancelRequest(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce
    );
    event DepositWithMessageReclaimed(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce
    );
    event LogWithdrawal(address indexed recipient, uint256 amount);
    event LogSetL2TokenBridge(uint256 value);
    event LogSetMaxTotalBalance(uint256 value);
    event LogSetMaxDeposit(uint256 value);
    event LogBridgeActivated();
    event LogDeposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce,
        uint256 fee
    );
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

    function isTokenContractRequired() internal pure virtual returns (bool) {
        return true;
    }

    function acceptDeposit(uint256 amount) internal virtual returns (uint256) {
        uint256 currentBalance = IERC20(bridgedToken()).balanceOf(address(this));
        require(currentBalance <= currentBalance + amount, "OVERFLOW");
        require(currentBalance + amount <= maxTotalBalance(), "MAX_BALANCE_EXCEEDED");
        Transfers.transferIn(bridgedToken(), msg.sender, amount);
        return msg.value;
    }

    function transferOutFunds(uint256 amount, address recipient) internal virtual {
        Transfers.transferOut(bridgedToken(), recipient, amount);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure virtual returns (string memory) {
        return "StarkWare_StarknetTokenBridge_2023_1";
    }

    function depositWithMessage(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message
    ) external payable {
        uint256 fee = acceptDeposit(amount);
        sendMessage(amount, l2Recipient, message, HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR, fee);
    }

    function deposit(uint256 amount, uint256 l2Recipient) external payable {
        uint256 fee = acceptDeposit(amount);
        uint256[] memory noMessage = new uint256[](0);
        sendMessage(amount, l2Recipient, noMessage, HANDLE_DEPOSIT_SELECTOR, fee);
    }

    function isInitialized() internal view override returns (bool) {
        if (!isTokenContractRequired()) {
            return (messagingContract() != IStarknetMessaging(address(0)));
        }
        return
            (messagingContract() != IStarknetMessaging(address(0))) &&
            (bridgedToken() != address(0));
    }

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    function validateInitData(bytes calldata data) internal view virtual override {
        require(data.length == 64, "ILLEGAL_DATA_SIZE");
        (address bridgedToken_, address messagingContract_) = abi.decode(data, (address, address));
        if (isTokenContractRequired()) {
            require(bridgedToken_.isContract(), "INVALID_BRIDGE_TOKEN_ADDRESS");
        } else {
            require(bridgedToken_ == address(0), "NON_ZERO_TOKEN_ADDRESS_PROVIDED");
        }
        require(messagingContract_.isContract(), "INVALID_MESSAGING_CONTRACT_ADDRESS");
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    /*
      Gets the addresses of bridgedToken & messagingContract from the ProxySupport initialize(),
      and sets the storage slot accordingly.
    */
    function initializeContractState(bytes calldata data) internal override {
        (address bridgedToken_, address messagingContract_) = abi.decode(data, (address, address));
        bridgedToken(bridgedToken_);
        messagingContract(messagingContract_);
    }

    function isValidL2Address(uint256 l2Address) internal pure returns (bool) {
        return (l2Address != 0 && isFelt(l2Address));
    }

    function isFelt(uint256 maybeFelt) internal pure returns (bool) {
        return (maybeFelt < CairoConstants.FIELD_PRIME);
    }

    modifier onlyActive() {
        require(isActive(), "NOT_ACTIVE_YET");
        _;
    }

    modifier onlyDepositor(uint256 nonce) {
        address depositor_ = depositors()[nonce];
        require(depositor_ != address(0x0), "NO_DEPOSIT_TO_CANCEL");
        require(depositor_ == msg.sender, "ONLY_DEPOSITOR");
        _;
    }

    function setL2TokenBridge(uint256 l2TokenBridge_) external onlyGovernanceAdmin {
        require(isInitialized(), "CONTRACT_NOT_INITIALIZED");
        require(isValidL2Address(l2TokenBridge_), "L2_ADDRESS_OUT_OF_RANGE");
        l2TokenBridge(l2TokenBridge_);
        setActive();
        emit LogSetL2TokenBridge(l2TokenBridge_);
        emit LogBridgeActivated();
    }

    /*
      Sets the maximum allowed balance of the bridge.

      Note: It is possible to set a lower value than the current total balance.
      In this case, deposits will not be possible, until enough withdrawls are done, such that the
      total balance is below the limit.
    */
    function setMaxTotalBalance(uint256 maxTotalBalance_) external onlyGovernanceAdmin {
        emit LogSetMaxTotalBalance(maxTotalBalance_);
        maxTotalBalance(maxTotalBalance_);
    }

    function setMaxDeposit(uint256 maxDeposit_) external onlyGovernanceAdmin {
        emit LogSetMaxDeposit(maxDeposit_);
        maxDeposit(maxDeposit_);
    }

    function depositMessagePayload(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message
    ) private pure returns (uint256[] memory) {
        uint256 HEADER_SIZE = 3;
        uint256[] memory payload = new uint256[](HEADER_SIZE + message.length);
        payload[0] = l2Recipient;
        payload[1] = amount & (UINT256_PART_SIZE - 1);
        payload[2] = amount >> UINT256_PART_SIZE_BITS;
        for (uint256 i = 0; i < message.length; i++) {
            require(isFelt(message[i]), "INVALID_MESSAGE_DATA");
            payload[i + HEADER_SIZE] = message[i];
        }
        return payload;
    }

    function depositMessagePayload(uint256 amount, uint256 l2Recipient)
        private
        pure
        returns (uint256[] memory)
    {
        uint256[] memory noMessage = new uint256[](0);
        return depositMessagePayload(amount, l2Recipient, noMessage);
    }

    function sendMessage(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message,
        uint256 selector,
        uint256 fee
    ) internal onlyActive {
        require(amount > 0, "ZERO_DEPOSIT");
        require(msg.value >= fee, "INSUFFICIENT_MSG_VALUE");
        require(isValidL2Address(l2Recipient), "L2_ADDRESS_OUT_OF_RANGE");
        require(amount <= maxDeposit(), "TRANSFER_TO_STARKNET_AMOUNT_EXCEEDED");

        (, uint256 nonce) = messagingContract().sendMessageToL2{value: fee}(
            l2TokenBridge(),
            selector,
            depositMessagePayload(amount, l2Recipient, message)
        );
        require(depositors()[nonce] == address(0x0), "DEPOSIT_ALREADY_REGISTERED");
        depositors()[nonce] = msg.sender;

        // The function exclusively supports two specific selectors, and any attempt to use an unknown
        // selector will result in a transaction failure.
        if (selector == HANDLE_DEPOSIT_SELECTOR) {
            emit LogDeposit(msg.sender, amount, l2Recipient, nonce, fee);
        } else {
            require(selector == HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR, "UNKNOWN_SELECTOR");
            emit DepositWithMessage(msg.sender, amount, l2Recipient, message, nonce, fee);
        }
    }

    function consumeMessage(uint256 amount, address recipient) internal onlyActive {
        uint256[] memory payload = new uint256[](4);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = uint256(uint160(recipient));
        payload[2] = amount & (UINT256_PART_SIZE - 1);
        payload[3] = amount >> UINT256_PART_SIZE_BITS;

        messagingContract().consumeMessageFromL2(l2TokenBridge(), payload);
    }

    function withdraw(uint256 amount, address recipient) public {
        // Make sure we don't accidentally burn funds.
        require(recipient != address(0x0), "INVALID_RECIPIENT");

        // The call to consumeMessage will succeed only if a matching L2->L1 message
        // exists and is ready for consumption.
        consumeMessage(amount, recipient);
        transferOutFunds(amount, recipient);

        emit LogWithdrawal(recipient, amount);
    }

    function withdraw(uint256 amount) external {
        withdraw(amount, msg.sender);
    }

    /*
      A deposit cancellation requires two steps:
      1. The depositor should send a depositCancelRequest request with deposit details & nonce.
      2. After a predetermined time (cancellation delay), the depositor can claim back the funds by
         calling depositReclaim (using the same arguments).

      Note: As long as the depositReclaim was not performed, the deposit may be processed, even if
            the cancellation delay time has already passed. Only the depositor is allowed to cancel
            a deposit, and only before depositReclaim was performed.
    */
    function depositCancelRequest(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient),
            nonce
        );

        emit LogDepositCancelRequest(msg.sender, amount, l2Recipient, nonce);
    }

    /*
        See: depositCancelRequest docstring.
    */
    function depositWithMessageCancelRequest(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(amount, l2Recipient, message),
            nonce
        );

        emit DepositWithMessageCancelRequest(msg.sender, amount, l2Recipient, message, nonce);
    }

    function depositWithMessageReclaim(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(amount, l2Recipient, message),
            nonce
        );

        transferOutFunds(amount, msg.sender);
        emit DepositWithMessageReclaimed(msg.sender, amount, l2Recipient, message, nonce);
    }

    function depositReclaim(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient),
            nonce
        );

        transferOutFunds(amount, msg.sender);
        emit LogDepositReclaimed(msg.sender, amount, l2Recipient, nonce);
    }
}
