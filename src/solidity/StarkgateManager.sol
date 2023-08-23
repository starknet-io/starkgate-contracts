// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/components/Roles.sol";
import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/solidity/libraries/NamedStorage.sol";
import "src/solidity/IStarkgateBridge.sol";
import "src/solidity/IStarkgateRegistry.sol";
import "src/solidity/StarkgateConstants.sol";

contract StarkgateManager is Identity, StarknetBridgeConstants, ProxySupport {
    using Addresses for address;
    // Random storage slot tags.
    string internal constant REGISTRY_TAG = "STARKGATE_MANAGER_REGISTRY_SLOT_TAG";
    string internal constant MULTI_BRIDGE_TAG = "STARKGATE_MANAGER_MULTI_BRIDGE_SLOT_TAG";

    // Storage Getters.
    function registry() internal view returns (address) {
        return NamedStorage.getAddressValue(REGISTRY_TAG);
    }

    function multiBridge() internal view returns (address) {
        return NamedStorage.getAddressValue(MULTI_BRIDGE_TAG);
    }

    // Storage Setters.
    function setRegistry(address contract_) internal {
        NamedStorage.setAddressValueOnce(REGISTRY_TAG, contract_);
    }

    function setMultiBridge(address contract_) internal {
        NamedStorage.setAddressValueOnce(MULTI_BRIDGE_TAG, contract_);
    }

    /**
      Returns a string that identifies the contract.
    */
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarkgateManager_2023_1";
    }

    /*
      Initializes the contract.
    */
    function initializeContractState(bytes calldata data) internal override {
        (address registry_, address multiBridge_) = abi.decode(data, (address, address));
        setRegistry(registry_);
        setMultiBridge(multiBridge_);
    }

    function isInitialized() internal view override returns (bool) {
        return registry() != address(0);
    }

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    function validateInitData(bytes calldata data) internal view virtual override {
        require(data.length == 64, "ILLEGAL_DATA_SIZE");
        (address registry_, address multiBridge_) = abi.decode(data, (address, address));
        require(registry_.isContract(), "INVALID_REGISTRY_CONTRACT_ADDRESS");
        require(multiBridge_.isContract(), "INVALID_BRIDGE_CONTRACT_ADDRESS");
    }

    function addExistingBridge(address token, address bridge) external onlyTokenAdmin {
        IStarkgateRegistry(registry()).enrollToken(token, bridge);
    }

    function deactivateToken(address token) external onlyTokenAdmin {
        IStarkgateRegistry(registry()).deactivateToken(token);
    }

    function enrollTokenBridge(address token) external {
        IStarkgateRegistry registryContract = IStarkgateRegistry(registry());
        require(registryContract.getBridge(token) != CANNOT_DEPLOY_BRIDGE, "CANNOT_DEPLOY_BRIDGE");
        registryContract.enrollToken(token, multiBridge());
        // TODO : Deploy bridge :
        //  IStarkgateBridge(multiBridge()).deployBridge(token);
    }
}
