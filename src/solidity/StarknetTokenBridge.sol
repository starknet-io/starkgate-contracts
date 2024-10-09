// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/solidity/libraries/NamedStorage.sol";
import "starkware/solidity/libraries/Transfers.sol";
import "starkware/solidity/tokens/ERC20/IERC20.sol";
import "starkware/solidity/tokens/ERC20/IERC20Metadata.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";
import "src/solidity/Fees.sol";
import "src/solidity/IStarkgateBridge.sol";
import "src/solidity/IStarkgateManager.sol";
import "src/solidity/IStarkgateRegistry.sol";
import "src/solidity/IStarkgateService.sol";
import "src/solidity/StarkgateConstants.sol";
import "src/solidity/StarkgateManager.sol";
import "src/solidity/StarknetTokenStorage.sol";
import "src/solidity/WithdrawalLimit.sol";
import "src/solidity/utils/Felt252.sol";

contract StarknetTokenBridge is
    IStarkgateBridge,
    IStarkgateService,
    Identity,
    Fees,
    StarknetTokenStorage,
    ProxySupport
{
    using Addresses for address;
    using Felt252 for string;
    using UintFelt252 for uint256;

    event TokenEnrollmentInitiated(address token, bytes32 deploymentMsgHash);
    event TokenDeactivated(address token);

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
    event WithdrawalLimitEnabled(address indexed sender, address indexed token);
    event WithdrawalLimitDisabled(address indexed sender, address indexed token);
    uint256 constant N_DEPOSIT_PAYLOAD_ARGS = 5;
    uint256 constant DEPOSIT_MESSAGE_FIXED_SIZE = 1;

    function identify() external pure virtual returns (string memory) {
        return "StarkWare_StarknetTokenBridge_2.0_5";
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
        WithdrawalLimit.setWithdrawLimitPct(WithdrawalLimit.DEFAULT_WITHDRAW_LIMIT_PCT);
    }

    function isInitialized() internal view virtual override returns (bool) {
        return address(messagingContract()) != address(0);
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    modifier onlyManager() {
        require(manager() == msg.sender, "ONLY_MANAGER");
        _;
    }

    modifier skipUnlessPending(address token) {
        if (tokenSettings()[token].tokenStatus != TokenStatus.Pending) return;
        _;
    }

    modifier onlyServicingToken(address token) {
        require(isServicingToken(token), "TOKEN_NOT_SERVICED");
        _;
    }

    function estimateDepositFeeWei() external pure returns (uint256) {
        return Fees.estimateDepositFee();
    }

    function estimateEnrollmentFeeWei() external pure returns (uint256) {
        return Fees.estimateEnrollmentFee();
    }

    // Virtual functions.
    function acceptDeposit(address token, uint256 amount) internal virtual returns (uint256) {
        Fees.checkFee(msg.value);
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        require(currentBalance + amount <= getMaxTotalBalance(token), "MAX_BALANCE_EXCEEDED");
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
        No return value, but it updates the token's status to 'Pending' and records the deployment message and expiration time.
        Emits a `TokenEnrollmentInitiated` event when the enrollment is initiated.
        Throws an error if the sender is not the manager or if the deployment message does not exist.
     */
    function enrollToken(address token) external payable virtual onlyManager {
        require(
            tokenSettings()[token].tokenStatus == TokenStatus.Unknown,
            "TOKEN_ALREADY_ENROLLED"
        );
        // send message.
        bytes32 deploymentMsgHash = sendDeployMessage(token);

        require(
            messagingContract().l1ToL2Messages(deploymentMsgHash) > 0,
            "DEPLOYMENT_MESSAGE_NOT_EXIST"
        );
        tokenSettings()[token].tokenStatus = TokenStatus.Pending;
        tokenSettings()[token].deploymentMsgHash = deploymentMsgHash;
        tokenSettings()[token].pendingDeploymentExpiration = block.timestamp + MAX_PENDING_DURATION;
        emit TokenEnrollmentInitiated(token, deploymentMsgHash);
    }

    function getStatus(address token) external view returns (TokenStatus) {
        return tokenSettings()[token].tokenStatus;
    }

    function isServicingToken(address token) public view returns (bool) {
        TokenStatus status = tokenSettings()[token].tokenStatus;
        return (status == TokenStatus.Pending || status == TokenStatus.Active);
    }

    /**
        Returns the remaining amount of withdrawal allowed for this day.
        If the daily allowance was not yet set, it is calculated and returned.
        If the withdraw limit is not enabled for that token - the uint256.max is returned.
     */
    function getRemainingIntradayAllowance(address token) external view returns (uint256) {
        return
            tokenSettings()[token].withdrawalLimitApplied
                ? WithdrawalLimit.getRemainingIntradayAllowance(token)
                : type(uint256).max;
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
    function deactivate(address token) external virtual onlyManager {
        require(tokenSettings()[token].tokenStatus != TokenStatus.Unknown, "UNKNOWN_TOKEN");
        tokenSettings()[token].tokenStatus = TokenStatus.Deactivated;
        emit TokenDeactivated(token);
    }

    /**
        Checks token deployment status.
        Relies on Starknet clearing L1-L2 message upon successful completion of deployment.
        Processing: Check the l1-l2 deployment message. Set status to `active` If consumed.
        If not consumed after the expected duration, it returns the status to unknown.
     */
    function checkDeploymentStatus(address token) public skipUnlessPending(token) {
        TokenSettings storage settings = tokenSettings()[token];
        bytes32 msgHash = settings.deploymentMsgHash;

        if (messagingContract().l1ToL2Messages(msgHash) == 0) {
            settings.tokenStatus = TokenStatus.Active;
        } else if (block.timestamp > settings.pendingDeploymentExpiration) {
            delete tokenSettings()[token];
            address registry = IStarkgateManager(manager()).getRegistry();
            IStarkgateRegistry(registry).selfRemove(token);
        }
    }

    function depositWithMessage(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata message
    ) external payable onlyServicingToken(token) {
        uint256 fee = acceptDeposit(token, amount);
        uint256 nonce = sendDepositMessage(
            token,
            amount,
            l2Recipient,
            message,
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            fee
        );
        emitDepositEvent(
            token,
            amount,
            l2Recipient,
            message,
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            nonce,
            fee
        );

        // Piggy-back the deposit tx to check and update the status of token bridge deployment.
        checkDeploymentStatus(token);
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 l2Recipient
    ) external payable onlyServicingToken(token) {
        uint256[] memory noMessage = new uint256[](0);
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

        // Piggy-back the deposit tx to check and update the status of token bridge deployment.
        checkDeploymentStatus(token);
    }

    function emitDepositEvent(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message,
        uint256 selector,
        uint256 nonce,
        uint256 fee
    ) internal {
        if (selector == HANDLE_TOKEN_DEPOSIT_SELECTOR) {
            emit Deposit(msg.sender, token, amount, l2Recipient, nonce, fee);
        } else {
            require(selector == HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR, "UNKNOWN_SELECTOR");
            emit DepositWithMessage(msg.sender, token, amount, l2Recipient, message, nonce, fee);
        }
    }

    function setL2TokenBridge(uint256 l2TokenBridge_) external onlyAppGovernor {
        require(isInitialized(), "CONTRACT_NOT_INITIALIZED");
        require(l2TokenBridge_.isValidL2Address(), "L2_ADDRESS_OUT_OF_RANGE");
        l2TokenBridge(l2TokenBridge_);
        emit SetL2TokenBridge(l2TokenBridge_);
    }

    /**
        Set withdrawal limit for a token.
     */
    function enableWithdrawalLimit(address token) external onlySecurityAgent {
        tokenSettings()[token].withdrawalLimitApplied = true;
        emit WithdrawalLimitEnabled(msg.sender, token);
    }

    /**
        Unset withdrawal limit for a token.
     */
    function disableWithdrawalLimit(address token) external onlySecurityAdmin {
        tokenSettings()[token].withdrawalLimitApplied = false;
        emit WithdrawalLimitDisabled(msg.sender, token);
    }

    /**
       Set the maximum allowed balance of the bridge.
       Note: It is possible to set a lower value than the current total balance.
       In this case, deposits will not be possible, until enough withdrawls are done, such that the
       total balance is below the limit.
     */
    function setMaxTotalBalance(address token, uint256 maxTotalBalance_) external onlyAppGovernor {
        require(maxTotalBalance_ != 0, "INVALID_MAX_TOTAL_BALANCE");
        emit SetMaxTotalBalance(token, maxTotalBalance_);
        tokenSettings()[token].maxTotalBalance = maxTotalBalance_;
    }

    // Returns the maximal allowed balance of the bridge
    // If the value is 0, it means that there is no limit.
    function getMaxTotalBalance(address token) public view returns (uint256) {
        uint256 maxTotalBalance = tokenSettings()[token].maxTotalBalance;
        return maxTotalBalance == 0 ? type(uint256).max : maxTotalBalance;
    }

    // The max depsoit limitation is deprecated.
    // For Backward compatibility, we return maxUint256, which means no limitation.
    function maxDeposit() external pure returns (uint256) {
        return type(uint256).max;
    }

    function deployMessagePayload(address token) private view returns (uint256[] memory) {
        IERC20Metadata erc20 = IERC20Metadata(token);
        uint256[] memory payload = new uint256[](4);
        payload[0] = uint256(uint160(token));
        payload[1] = erc20.name().safeToFelt();
        payload[2] = erc20.symbol().safeToFelt();
        payload[3] = uint256(erc20.decimals());
        return payload;
    }

    function depositMessagePayload(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        bool withMessage,
        uint256[] memory message
    ) private view returns (uint256[] memory) {
        uint256 MESSAGE_OFFSET = withMessage
            ? N_DEPOSIT_PAYLOAD_ARGS + DEPOSIT_MESSAGE_FIXED_SIZE
            : N_DEPOSIT_PAYLOAD_ARGS;
        uint256[] memory payload = new uint256[](MESSAGE_OFFSET + message.length);
        payload[0] = uint256(uint160(token));
        payload[1] = uint256(uint160(msg.sender));
        payload[2] = l2Recipient;
        payload[3] = amount & (UINT256_PART_SIZE - 1);
        payload[4] = amount >> UINT256_PART_SIZE_BITS;
        if (withMessage) {
            payload[MESSAGE_OFFSET - 1] = message.length;
            for (uint256 i = 0; i < message.length; i++) {
                require(message[i].isFelt(), "INVALID_MESSAGE_DATA");
                payload[i + MESSAGE_OFFSET] = message[i];
            }
        }
        return payload;
    }

    function depositMessagePayload(
        address token,
        uint256 amount,
        uint256 l2Recipient
    ) private view returns (uint256[] memory) {
        uint256[] memory noMessage = new uint256[](0);
        return
            depositMessagePayload(
                token,
                amount,
                l2Recipient,
                false, /*without message*/
                noMessage
            );
    }

    function sendDeployMessage(address token) internal returns (bytes32) {
        require(l2TokenBridge() != 0, "L2_BRIDGE_NOT_SET");
        Fees.checkFee(msg.value);

        (bytes32 deploymentMsgHash, ) = messagingContract().sendMessageToL2{value: msg.value}(
            l2TokenBridge(),
            HANDLE_TOKEN_DEPLOYMENT_SELECTOR,
            deployMessagePayload(token)
        );
        return deploymentMsgHash;
    }

    function sendDepositMessage(
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256[] memory message,
        uint256 selector,
        uint256 fee
    ) internal returns (uint256) {
        require(l2TokenBridge() != 0, "L2_BRIDGE_NOT_SET");
        require(amount > 0, "ZERO_DEPOSIT");
        require(l2Recipient.isValidL2Address(), "L2_ADDRESS_OUT_OF_RANGE");

        bool isWithMsg = selector == HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR;
        (, uint256 nonce) = messagingContract().sendMessageToL2{value: fee}(
            l2TokenBridge(),
            selector,
            depositMessagePayload(token, amount, l2Recipient, isWithMsg, message)
        );

        // The function exclusively supports two specific selectors, and any attempt to use an unknown
        // selector will result in a transaction failure.
        return nonce;
    }

    function consumeMessage(
        address token,
        uint256 amount,
        address recipient
    ) internal virtual {
        require(l2TokenBridge() != 0, "L2_BRIDGE_NOT_SET");
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
        // Check if the withdrawal limit is enabled for that token.
        if (tokenSettings()[token].withdrawalLimitApplied) {
            // If the withdrawal limit is enabled, consume the quota.
            WithdrawalLimit.consumeWithdrawQuota(token, amount);
        }
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
    ) external {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_TOKEN_DEPOSIT_SELECTOR,
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
    ) external {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(
                token,
                amount,
                l2Recipient,
                true, /*with message*/
                message
            ),
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
    ) external {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
            depositMessagePayload(
                token,
                amount,
                l2Recipient,
                true, /*with message*/
                message
            ),
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
    ) external {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            HANDLE_TOKEN_DEPOSIT_SELECTOR,
            depositMessagePayload(token, amount, l2Recipient),
            nonce
        );

        transferOutFunds(token, amount, msg.sender);
        emit DepositReclaimed(msg.sender, token, amount, l2Recipient, nonce);
    }
}
