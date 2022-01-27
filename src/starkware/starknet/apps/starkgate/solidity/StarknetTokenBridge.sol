// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "contracts/starkware/contracts/components/GenericGovernance.sol";
import "contracts/starkware/contracts/interfaces/ContractInitializer.sol";
import "contracts/starkware/contracts/interfaces/ProxySupport.sol";
import "contracts/starkware/cairo/eth/CairoConstants.sol";
import "contracts/starkware/starknet/apps/starkgate/solidity/StarknetTokenStorage.sol";
import "contracts/starkware/starknet/eth/IStarknetMessaging.sol";

abstract contract StarknetTokenBridge is
    StarknetTokenStorage,
    GenericGovernance,
    ContractInitializer,
    ProxySupport
{
    event LogDeposit(address sender, uint256 amount, uint256 l2Recipient);
    event LogWithdrawal(address recipient, uint256 amount);
    event LogSetL2TokenBridge(uint256 value);
    event LogSetMaxTotalBalance(uint256 value);
    event LogSetMaxDeposit(uint256 value);

    constructor() internal GenericGovernance("STARKWARE_DEFAULT_GOVERNANCE_INFO") {}

    function isInitialized() internal view override returns (bool) {
        return messagingContract() != IStarknetMessaging(0);
    }

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    function validateInitData(bytes calldata data) internal pure override {
        require(data.length == 64, "ILLEGAL_DATA_SIZE");
    }

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

    // The selector of the deposit handler in L2.
    uint256 constant DEPOSIT_SELECTOR =
        1285101517810983806491589552491143496277809242732141897358598292095611420389;
    uint256 constant TRANSFER_FROM_STARKNET = 0;
    uint256 constant UINT256_PART_SIZE_BITS = 128;
    uint256 constant UINT256_PART_SIZE = 2**UINT256_PART_SIZE_BITS;

    modifier isValidL2Address(uint256 l2Address) {
        require(l2Address != 0, "L2_ADDRESS_OUT_OF_RANGE");
        require(l2Address < CairoConstants.FIELD_PRIME, "L2_ADDRESS_OUT_OF_RANGE");
        _;
    }

    modifier l2TokenBridgeNotSet() {
        require(l2TokenBridge() == 0, "L2_TOKEN_CONTRACT_ALREADY_SET");
        _;
    }

    modifier l2TokenBridgeSet() {
        require(l2TokenBridge() != 0, "L2_TOKEN_CONTRACT_NOT_SET");
        _;
    }

    function setL2TokenBridge(uint256 l2TokenBridge_)
        external
        l2TokenBridgeNotSet
        isValidL2Address(l2TokenBridge_)
        onlyGovernance
    {
        emit LogSetL2TokenBridge(l2TokenBridge_);
        l2TokenBridge(l2TokenBridge_);
    }

    function setMaxTotalBalance(uint256 maxTotalBalance_) external onlyGovernance {
        emit LogSetMaxTotalBalance(maxTotalBalance_);
        maxTotalBalance(maxTotalBalance_);
    }

    function setMaxDeposit(uint256 maxDeposit_) external onlyGovernance {
        emit LogSetMaxDeposit(maxDeposit_);
        maxDeposit(maxDeposit_);
    }

    function sendMessage(uint256 amount, uint256 l2Recipient)
        internal
        l2TokenBridgeSet
        isValidL2Address(l2Recipient)
    {
        require(amount <= maxDeposit(), "TRANSFER_TO_STARKNET_AMOUNT_EXCEEDED");
        emit LogDeposit(msg.sender, amount, l2Recipient);

        uint256[] memory payload = new uint256[](3);
        payload[0] = l2Recipient;
        payload[1] = amount & (UINT256_PART_SIZE - 1);
        payload[2] = amount >> UINT256_PART_SIZE_BITS;
        messagingContract().sendMessageToL2(l2TokenBridge(), DEPOSIT_SELECTOR, payload);
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

    function withdraw(uint256 amount, address recipient) public virtual;

    function withdraw(uint256 amount) external {
        withdraw(amount, msg.sender);
    }
}
