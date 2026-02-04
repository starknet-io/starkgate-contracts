// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "src/solidity/IStarkgateRegistry.sol";
import "src/solidity/IStarkgateService.sol";
import "src/solidity/StarkgateConstants.sol";
import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/solidity/libraries/NamedStorage.sol";

contract StarkgateRegistry is Identity, ProxySupport, IStarkgateRegistry {
    using Addresses for address;
    // Named storage slot tags.
    string internal constant MANAGER_TAG = "STARKGATE_REGISTRY_MANAGER_SLOT_TAG";
    string internal constant TOKEN_TO_BRIDGE_TAG = "STARKGATE_REGISTRY_TOKEN_TO_BRIDGE_SLOT_TAG";
    string internal constant TOKEN_TO_WITHDRAWAL_BRIDGES_TAG =
        "STARKGATE_REGISTRY_TOKEN_TO_WITHDRAWAL_BRIDGES_SLOT_TAG";
    event TokenSelfRemoved(address indexed token, address indexed bridge);
    event TokenStatusBlocked(address indexed token);
    event TokenEnlisted(address indexed token, address indexed bridge);

    // Storage Getters.
    function manager() internal view returns (address) {
        return NamedStorage.getAddressValue(MANAGER_TAG);
    }

    // Mapping that establishes a connection between tokens and their respective active bridge
    // contract addresses, enabling seamless deposits for each token.
    function tokenToBridge() internal pure returns (mapping(address => address) storage) {
        return NamedStorage.addressToAddressMapping(TOKEN_TO_BRIDGE_TAG);
    }

    // Mapping connecting token contract addresses to arrays of bridge contract addresses,
    // indicating bridges that have supported withdrawals for each respective token.
    function tokenToWithdrawalBridges()
        internal
        pure
        returns (mapping(address => address[]) storage)
    {
        return NamedStorage.addressToAddressListMapping(TOKEN_TO_WITHDRAWAL_BRIDGES_TAG);
    }

    modifier onlyManager() {
        require(manager() == msg.sender, "ONLY_MANAGER");
        _;
    }

    function identify() external pure override returns (string memory) {
        return "StarkWare_StarkgateRegistry_2.0_1";
    }

    /*
      Initializes the contract.
    */
    function initializeContractState(bytes calldata data) internal override {
        address manager_ = abi.decode(data, (address));
        NamedStorage.setAddressValueOnce(MANAGER_TAG, manager_);
    }

    function isInitialized() internal view override returns (bool) {
        return manager() != address(0);
    }

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    function validateInitData(bytes calldata data) internal view virtual override {
        require(data.length == 32, "ILLEGAL_DATA_SIZE");
        address manager_ = abi.decode(data, (address));
        require(manager_.isContract(), "INVALID_MANAGER_CONTRACT_ADDRESS");
    }

    function getBridge(address token) external view returns (address) {
        return tokenToBridge()[token];
    }

    /**
      Add a mapping between a token and the bridge handling it.
      Ensuring unique enrollment.
    */
    function enlistToken(address token, address bridge) external onlyManager {
        address currentBridge = tokenToBridge()[token];
        require(
            currentBridge == address(0) || currentBridge == BLOCKED_TOKEN,
            "TOKEN_ALREADY_ENROLLED"
        );
        emit TokenEnlisted(token, bridge);
        tokenToBridge()[token] = bridge;
        if (!containsAddress(tokenToWithdrawalBridges()[token], bridge)) {
            tokenToWithdrawalBridges()[token].push(bridge);
        }
    }

    /**
      Block a specific token from being used in the StarkGate.
      A blocked token cannot be deployed.
    */
    function blockToken(address token) external onlyManager {
        emit TokenStatusBlocked(token);
        tokenToBridge()[token] = BLOCKED_TOKEN;
    }

    function getWithdrawalBridges(address token) external view returns (address[] memory bridges) {
        return tokenToWithdrawalBridges()[token];
    }

    /**
      Using this function a bridge removes enlisting of its token from the registry.
      The bridge must implement `isServicingToken(address token)` (see `IStarkgateService`).
    */
    function selfRemove(address token) external {
        require(tokenToBridge()[token] == msg.sender, "BRIDGE_MISMATCH_CANNOT_REMOVE_TOKEN");
        require(!IStarkgateService(msg.sender).isServicingToken(token), "TOKEN_IS_STILL_SERVICED");
        emit TokenSelfRemoved(token, msg.sender);
        tokenToBridge()[token] = address(0x0);
    }

    function containsAddress(address[] memory addresses, address target)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] == target) {
                return true;
            }
        }
        return false;
    }
}
