// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/solidity/components/GenericGovernance.sol";
import "contracts/starkware/solidity/interfaces/Identity.sol";
import "contracts/starkware/solidity/interfaces/ProxySupport.sol";
import "contracts/starkware/cairo/eth/CairoConstants.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/StarknetBridgeConstatns.sol";
import "contracts/starkware/starknet/apps/starkgate/eth/StarknetTokenStorage.sol";
import "contracts/starkware/starknet/solidity/IStarknetMessaging.sol";

abstract contract StarknetTokenBridge is
    Identity,
    StarknetTokenStorage,
    StarknetBridgeConstatns,
    GenericGovernance,
    ProxySupport
{
    event LogDeposit(address indexed sender, uint256 amount, uint256 indexed l2Recipient);
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
    event LogWithdrawal(address indexed recipient, uint256 amount);
    event LogSetL2TokenBridge(uint256 value);
    event LogSetMaxTotalBalance(uint256 value);
    event LogSetMaxDeposit(uint256 value);

    function withdraw(uint256 amount, address recipient) public virtual;

    function transferOutFunds(uint256 amount, address recipient) internal virtual;

    /*
      The constructor is in use here only to set the immutable tag in GenericGovernance.
    */
    constructor() internal GenericGovernance(GOVERNANCE_TAG) {}

    function isInitialized() internal view override returns (bool) {
        return messagingContract() != IStarknetMessaging(0);
    }

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    function validateInitData(bytes calldata data) internal pure override {
        require(data.length == 64, "ILLEGAL_DATA_SIZE");
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
        (address bridgedToken_, IStarknetMessaging messagingContract_) = abi.decode(
            data,
            (address, IStarknetMessaging)
        );
        bridgedToken(bridgedToken_);
        messagingContract(messagingContract_);
    }

    modifier isValidL2Address(uint256 l2Address) {
        require(l2Address != 0, "L2_ADDRESS_OUT_OF_RANGE");
        require(l2Address < CairoConstants.FIELD_PRIME, "L2_ADDRESS_OUT_OF_RANGE");
        _;
    }

    modifier l2TokenBridgeSet() {
        require(l2TokenBridge() != 0, "L2_TOKEN_CONTRACT_NOT_SET");
        _;
    }

    modifier onlyDepositor(uint256 nonce) {
        address depositor_ = depositors()[nonce];
        require(depositor_ != address(0x0), "NO_DEPOSIT_TO_CANCEL");
        require(depositor_ == msg.sender, "ONLY_DEPOSITOR");
        _;
    }

    function setL2TokenBridge(uint256 l2TokenBridge_)
        external
        isValidL2Address(l2TokenBridge_)
        onlyGovernance
    {
        emit LogSetL2TokenBridge(l2TokenBridge_);
        l2TokenBridge(l2TokenBridge_);
    }

    /*
      Sets the maximum allowed balance of the bridge.

      Note: It is possible to set a lower value than the current total balance.
      In this case, deposits will not be possible, until enough withdrawls are done, such that the
      total balance gets below the limit.
    */
    function setMaxTotalBalance(uint256 maxTotalBalance_) external onlyGovernance {
        emit LogSetMaxTotalBalance(maxTotalBalance_);
        maxTotalBalance(maxTotalBalance_);
    }

    function setMaxDeposit(uint256 maxDeposit_) external onlyGovernance {
        emit LogSetMaxDeposit(maxDeposit_);
        maxDeposit(maxDeposit_);
    }

    function depositMessagePayload(uint256 amount, uint256 l2Recipient)
        private
        returns (uint256[] memory)
    {
        uint256[] memory payload = new uint256[](3);
        payload[0] = l2Recipient;
        payload[1] = amount & (UINT256_PART_SIZE - 1);
        payload[2] = amount >> UINT256_PART_SIZE_BITS;
        return payload;
    }

    function sendMessage(uint256 amount, uint256 l2Recipient)
        internal
        l2TokenBridgeSet
        isValidL2Address(l2Recipient)
    {
        require(amount <= maxDeposit(), "TRANSFER_TO_STARKNET_AMOUNT_EXCEEDED");
        emit LogDeposit(msg.sender, amount, l2Recipient);

        (, uint256 nonce) = messagingContract().sendMessageToL2(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient)
        );
        require(depositors()[nonce] == address(0x0), "DEPOSIT_ALREADY_REGISTERED");
        depositors()[nonce] = msg.sender;
    }

    function consumeMessage(uint256 amount, address recipient) internal {
        emit LogWithdrawal(recipient, amount);

        uint256[] memory payload = new uint256[](4);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = uint256(recipient);
        payload[2] = amount & (UINT256_PART_SIZE - 1);
        payload[3] = amount >> UINT256_PART_SIZE_BITS;

        messagingContract().consumeMessageFromL2(l2TokenBridge(), payload);
    }

    function withdraw(uint256 amount) external {
        withdraw(amount, msg.sender);
    }

    /*
      A deposit cancellation requires two steps:
      1. The depositor should send a depositCancelRequest request with deposit details & nonce.
      2. Only the depositor is allowed to cancel a deposit.
      3. After a certain threshold time, (cancellation delay), they can claim back the funds
         by calling depositReclaim (using the same arguments).

      The nonce should be extracted from the LogMessageToL2 event that was emitted by the
      StarknetMessaging contract upon deposit.

      Note: As long as the depositReclaim was not performed, the deposit may be processed,
            even if the cancellation delay time as already passed.
    */
    function depositCancelRequest(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyDepositor(nonce) {
        messagingContract().startL1ToL2MessageCancellation(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient),
            nonce
        );

        // Only the depositor is allowed to cancel a deposit.

        emit LogDepositCancelRequest(msg.sender, amount, l2Recipient, nonce);
    }

    function depositReclaim(
        uint256 amount,
        uint256 l2Recipient,
        uint256 nonce
    ) external onlyDepositor(nonce) {
        messagingContract().cancelL1ToL2Message(
            l2TokenBridge(),
            DEPOSIT_SELECTOR,
            depositMessagePayload(amount, l2Recipient),
            nonce
        );

        transferOutFunds(amount, msg.sender);
        emit LogDepositReclaimed(msg.sender, amount, l2Recipient, nonce);
    }
}
