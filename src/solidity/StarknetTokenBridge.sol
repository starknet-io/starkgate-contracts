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
import "src/solidity/StarkgateManager.sol";

contract StarknetTokenBridge is
    Identity,
    StarknetTokenStorage,
    StarknetBridgeConstants,
    ProxySupport
{
    using Addresses for address;
    event DepositWithMessage(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce,
        uint256 fee
    );
    event DepositWithMessageCancelRequest(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce
    );
    event DepositWithMessageReclaimed(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] message,
        uint256 nonce
    );
    event Withdrawal(address indexed recipient, address indexed token, uint256 amount);
    event SetL2TokenBridge(uint256 value);
    event SetMaxTotalBalance(address indexed token, uint256 value);
    event BridgeActivated();
    event Deposit(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce,
        uint256 fee
    );
    event DepositCancelRequest(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce
    );
    event DepositReclaimed(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256 nonce
    );

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure virtual returns (string memory) {
        return "StarkWare_StarknetTokenBridge_2023_1";
    }

    function validateInitData(bytes calldata data) internal view virtual override {
        require(data.length == 64, "ILLEGAL_DATA_SIZE");
        (address manager_, address messagingContract_) = abi.decode(data, (address, address));
        require(messagingContract_.isContract(), "INVALID_MESSAGING_CONTRACT_ADDRESS");
        require(manager_.isContract(), "INVALID_MANAGER_CONTRACT_ADDRESS");
    }

    /*
      Gets the addresses of bridgedToken & messagingContract from the ProxySupport initialize(),
      and sets the storage slot accordingly.
    */
    function initializeContractState(bytes calldata data) internal override {
        (address manager_, address messagingContract_) = abi.decode(data, (address, address));
        messagingContract(messagingContract_);
        setManager(manager_);
    }

    function isInitialized() internal view virtual override returns (bool) {
        return
            (messagingContract() != IStarknetMessaging(address(0))) && (manager() != address(0x0));
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    // Modifiers.
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

    modifier onlyManager() {
        require(manager() == msg.sender, "ONLY_MANAGER");
        _;
    }

    modifier skipUnlessPending(address token) {
        if (tokenSettings()[token].tokenStatus != TokenStatus.Pending) return;
        _;
    }

    // Virtual functions.
    function acceptDeposit(address token, uint256 amount) internal virtual returns (uint256) {
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        require(currentBalance <= currentBalance + amount, "OVERFLOW");
        require(
            currentBalance + amount <= tokenSettings()[token].maxTotalBalance,
            "MAX_BALANCE_EXCEEDED"
        );
        Transfers.transferIn(token, msg.sender, amount);
        return msg.value;
    }

    function transferOutFunds(
        address token,
        uint256 amount,
        address recipient
    ) internal virtual {
        Transfers.transferOut(token, recipient, amount);
    }

    /**
        Initiates the enrollment of a token into the system.
        This function is used to initiate the enrollment process of a token.
        The token is marked as 'Pending' because the success of the deployment is uncertain at this stage.
        The deployment message's existence is checked, indicating that deployment has been attempted.
        The success of the deployment is determined at a later stage during the application's lifecycle.
        Only the manager, who initiates the deployment, can call this function.

        @param token The address of the token contract to be enrolled.
        @param deploymentMsgHash The hash of the deployment message.
        No return value, but it updates the token's status to 'Pending' and records the deployment message and expiration time.
        Emits a `TokenEnrollmentInitiated` event when the enrollment is initiated.
        Throws an error if the sender is not the manager or if the deployment message does not exist.
     */
    // TODO : Add test.
    function enrollToken(address token, bytes32 deploymentMsgHash) external virtual onlyManager {
        require(
            tokenSettings()[token].tokenStatus == TokenStatus.Unknown,
            "TOKEN_ALREADY_ENROLLED"
        );
        require(
            messagingContract().l1ToL2Messages(deploymentMsgHash) > 0,
            "DEPLOYMENT_MESSAGE_NOT_EXIST"
        );
        tokenSettings()[token].tokenStatus = TokenStatus.Pending;
        tokenSettings()[token].deploymentMsgHash = deploymentMsgHash;
        tokenSettings()[token].pendingDeploymentExpiration = block.timestamp + MAX_PENDING_DURATION;
        // TODO : Emit event.
    }

    /**
        Deactivates a token in the system.
        This function is used to deactivate a token that was previously enrolled.
        Only the manager, who initiated the enrollment, can call this function.

        @param token The address of the token contract to be deactivated.
        No return value, but it updates the token's status to 'Deactivated'.
        Emits a `TokenDeactivated` event when the deactivation is successful.
        Throws an error if the token is not enrolled or if the sender is not the manager.

     */
    // TODO : Add test.
    function deactivate(address token) external virtual onlyManager {
        require(tokenSettings()[token].tokenStatus != TokenStatus.Unknown, "UNKNOWN_TOKEN");
        tokenSettings()[token].tokenStatus = TokenStatus.Deactivated;
        // TODO : Emit event.
    }

    /**
        Checks token deployment status.
        Relies on Starknet clearing L1-L2 message upon successful completion of deployment.
        Processing: Check the l1-l2 deployment message. Set status to `active` If consumed.
        If not consumed after the expected duration, it returns the status to unknown.
     */
    // TODO : Add test.
    function checkDeploymentStatus(address token) internal skipUnlessPending(token) {
        TokenSettings storage settings = tokenSettings()[token];
        bytes32 msgHash = settings.deploymentMsgHash;

        if (messagingContract().l1ToL2Messages(msgHash) == 0) {
            settings.tokenStatus = TokenStatus.Active;
        } else if (block.timestamp > settings.pendingDeploymentExpiration) {
            delete tokenSettings()[token];
            // TODO : self remove form registry.
        }
    }

    function depositWithMessage(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message
    ) external payable {
        uint256 fee = acceptDeposit(token, amount);
        sendMessage(token, amount, l2Recipient, message, HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR, fee);

        // Piggy-bag the deposit tx to check and update the status of token bridge deployment.
        checkDeploymentStatus(token);
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 l2Recipient
    ) external payable {
        uint256 fee = acceptDeposit(token, amount);
        uint256[] memory noMessage = new uint256[](0);
        sendMessage(token, amount, l2Recipient, noMessage, HANDLE_DEPOSIT_SELECTOR, fee);

        // Piggy-bag the deposit tx to check and update the status of token bridge deployment.
        checkDeploymentStatus(token);
    }

    function isValidL2Address(uint256 l2Address) internal pure returns (bool) {
        return (l2Address != 0 && isFelt(l2Address));
    }

    function isFelt(uint256 maybeFelt) internal pure returns (bool) {
        return (maybeFelt < CairoConstants.FIELD_PRIME);
    }

    function setL2TokenBridge(uint256 l2TokenBridge_) external onlyGovernanceAdmin {
        require(isInitialized(), "CONTRACT_NOT_INITIALIZED");
        require(isValidL2Address(l2TokenBridge_), "L2_ADDRESS_OUT_OF_RANGE");
        l2TokenBridge(l2TokenBridge_);
        setActive();
        emit SetL2TokenBridge(l2TokenBridge_);
        emit BridgeActivated();
    }

    /*
      Sets the maximum allowed balance of the bridge.

      Note: It is possible to set a lower value than the current total balance.
      In this case, deposits will not be possible, until enough withdrawls are done, such that the
      total balance is below the limit.
    */
    // TODO : Apply this function only for managed tokens.
    function setMaxTotalBalance(address token, uint256 maxTotalBalance_)
        external
        onlyGovernanceAdmin
    {
        emit SetMaxTotalBalance(token, maxTotalBalance_);
        tokenSettings()[token].maxTotalBalance = maxTotalBalance_;
    }

    function depositMessagePayload(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message
    ) private pure returns (uint256[] memory) {
        uint256 HEADER_SIZE = 4;
        uint256[] memory payload = new uint256[](HEADER_SIZE + message.length);
        payload[0] = l2Recipient;
        payload[1] = uint256(uint160(token));
        payload[2] = amount & (UINT256_PART_SIZE - 1);
        payload[3] = amount >> UINT256_PART_SIZE_BITS;
        for (uint256 i = 0; i < message.length; i++) {
            require(isFelt(message[i]), "INVALID_MESSAGE_DATA");
            payload[i + HEADER_SIZE] = message[i];
        }
        return payload;
    }

    function depositMessagePayload(
        address token,
        uint256 amount,
        uint256 l2Recipient
    ) private pure returns (uint256[] memory) {
        uint256[] memory noMessage = new uint256[](0);
        return depositMessagePayload(token, amount, l2Recipient, noMessage);
    }

    function sendMessage(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message,
        uint256 selector,
        uint256 fee
    ) internal onlyActive {
        require(amount > 0, "ZERO_DEPOSIT");
        require(msg.value >= fee, "INSUFFICIENT_MSG_VALUE");
        require(isValidL2Address(l2Recipient), "L2_ADDRESS_OUT_OF_RANGE");

        (, uint256 nonce) = messagingContract().sendMessageToL2{value: fee}(
            l2TokenBridge(),
            selector,
            depositMessagePayload(token, amount, l2Recipient, message)
        );
        require(depositors()[nonce] == address(0x0), "DEPOSIT_ALREADY_REGISTERED");
        depositors()[nonce] = msg.sender;

        // The function exclusively supports two specific selectors, and any attempt to use an unknown
        // selector will result in a transaction failure.
        if (selector == HANDLE_DEPOSIT_SELECTOR) {
            emit Deposit(msg.sender, token, amount, l2Recipient, nonce, fee);
        } else {
            require(selector == HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR, "UNKNOWN_SELECTOR");
            emit DepositWithMessage(msg.sender, token, amount, l2Recipient, message, nonce, fee);
        }
    }

    function consumeMessage(
        address token,
        uint256 amount,
        address recipient
    ) internal onlyActive {
        uint256[] memory payload = new uint256[](5);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = uint256(uint160(recipient));
        payload[2] = uint256(uint160(token));
        payload[3] = amount & (UINT256_PART_SIZE - 1);
        payload[4] = amount >> UINT256_PART_SIZE_BITS;

        messagingContract().consumeMessageFromL2(l2TokenBridge(), payload);
    }

    function withdraw(
        address token,
        uint256 amount,
        address recipient
    ) public {
        // Make sure we don't accidentally burn funds.
        require(recipient != address(0x0), "INVALID_RECIPIENT");

        // The call to consumeMessage will succeed only if a matching L2->L1 message
        // exists and is ready for consumption.
        consumeMessage(token, amount, recipient);
        transferOutFunds(token, amount, recipient);

        emit Withdrawal(recipient, token, amount);
    }

    function withdraw(address token, uint256 amount) external {
        withdraw(token, amount, msg.sender);
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
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            depositMessagePayload(token, amount, l2Recipient),
            nonce
        );

        emit DepositCancelRequest(msg.sender, token, amount, l2Recipient, nonce);
    }

    /*
        See: depositCancelRequest docstring.
    */
    function depositWithMessageCancelRequest(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(token, amount, l2Recipient, message),
            nonce
        );

        emit DepositWithMessageCancelRequest(
            msg.sender,
            token,
            amount,
            l2Recipient,
            message,
            nonce
        );
    }

    function depositWithMessageReclaim(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(token, amount, l2Recipient, message),
            nonce
        );

        transferOutFunds(token, amount, msg.sender);
        emit DepositWithMessageReclaimed(msg.sender, token, amount, l2Recipient, message, nonce);
    }

    function depositReclaim(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_SELECTOR,
            depositMessagePayload(token, amount, l2Recipient),
            nonce
        );

        transferOutFunds(token, amount, msg.sender);
        emit DepositReclaimed(msg.sender, token, amount, l2Recipient, nonce);
    }
}
