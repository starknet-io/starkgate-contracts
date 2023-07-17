// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/components/GenericGovernance.sol";
import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/cairo/eth/CairoConstants.sol";
import "src/solidity/StarknetBridgeConstants.sol";
import "src/solidity/StarknetTokenStorage.sol";
import "starkware/starknet/solidity/IStarknetMessaging.sol";

abstract contract StarknetTokenBridge is
    Identity,
    StarknetTokenStorage,
    StarknetBridgeConstants,
    GenericGovernance,
    ProxySupport
{
    using Addresses for address;
    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] receipt,
        uint256 nonce,
        uint256 fee
    );
    event DepositCancelRequest(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] receipt,
        uint256 nonce
    );
    event DepositReclaimed(
        address indexed sender,
        uint256 amount,
        uint256 indexed l2Recipient,
        uint256[] receipt,
        uint256 nonce
    );
    event LogWithdrawal(address indexed recipient, uint256 amount);
    event LogSetL2TokenBridge(uint256 value);
    event LogSetMaxTotalBalance(uint256 value);
    event LogSetMaxDeposit(uint256 value);
    event LogBridgeActivated();

    // Deprecated events.
    // These events are no longer emitted, but left in ABI for backward compatibility.
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

    function deposit(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata receipt
    ) external payable virtual;

    function transferOutFunds(uint256 amount, address recipient) internal virtual;

    /*
      The constructor is in use here only to set the immutable tag in GenericGovernance.
    */
    constructor() GenericGovernance(GOVERNANCE_TAG) {}

    function isTokenContractRequired() internal pure virtual returns (bool) {
        return true;
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
        return (l2Address > 0 && l2Address < CairoConstants.FIELD_PRIME);
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

    function setL2TokenBridge(uint256 l2TokenBridge_) external onlyGovernance {
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
    function setMaxTotalBalance(uint256 maxTotalBalance_) external onlyGovernance {
        emit LogSetMaxTotalBalance(maxTotalBalance_);
        maxTotalBalance(maxTotalBalance_);
    }

    function setMaxDeposit(uint256 maxDeposit_) external onlyGovernance {
        emit LogSetMaxDeposit(maxDeposit_);
        maxDeposit(maxDeposit_);
    }

    function depositMessagePayload(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata receipt
    ) private pure returns (uint256[] memory) {
        uint256 HEADER_SIZE = 3;
        uint256[] memory payload = new uint256[](HEADER_SIZE + receipt.length);
        payload[0] = l2Recipient;
        payload[1] = amount & (UINT256_PART_SIZE - 1);
        payload[2] = amount >> UINT256_PART_SIZE_BITS;
        for (uint256 i = HEADER_SIZE; i < payload.length; i++) {
            payload[i] = receipt[i - HEADER_SIZE];
        }
        return payload;
    }

    function sendMessage(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata receipt,
        uint256 fee
    ) internal onlyActive {
        require(amount > 0, "ZERO_DEPOSIT");
        require(msg.value >= fee, "INSUFFICIENT_MSG_VALUE");
        require(isValidL2Address(l2Recipient), "L2_ADDRESS_OUT_OF_RANGE");
        require(amount <= maxDeposit(), "TRANSFER_TO_STARKNET_AMOUNT_EXCEEDED");

        (, uint256 nonce) = messagingContract().sendMessageToL2{value: fee}(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient, receipt)
        );
        require(depositors()[nonce] == address(0x0), "DEPOSIT_ALREADY_REGISTERED");
        depositors()[nonce] = msg.sender;
        emit Deposit(msg.sender, amount, l2Recipient, receipt, nonce, fee);
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
        uint256[] calldata receipt,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient, receipt),
            nonce
        );

        // Only the depositor is allowed to cancel a deposit.

        emit DepositCancelRequest(msg.sender, amount, l2Recipient, receipt, nonce);
    }

    function depositReclaim(
        uint256 amount,
        uint256 l2Recipient,
        uint256[] calldata receipt,
        uint256 nonce
    ) external onlyActive onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient, receipt),
            nonce
        );

        transferOutFunds(amount, msg.sender);
        emit DepositReclaimed(msg.sender, amount, l2Recipient, receipt, nonce);
    }
}
