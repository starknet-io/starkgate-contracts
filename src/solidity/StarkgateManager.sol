// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/components/Roles.sol";
import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "starkware/solidity/libraries/Addresses.sol";
import "starkware/solidity/libraries/NamedStorage.sol";
import "src/solidity/IStarkgateBridge.sol";
import "src/solidity/IStarkgateManager.sol";
import "src/solidity/IStarkgateRegistry.sol";
import "src/solidity/StarkgateConstants.sol";

contract StarkgateManager is Identity, IStarkgateManager, ProxySupport {
    using Addresses for address;
    // Named storage slot tags.
    string internal constant REGISTRY_TAG = "STARKGATE_MANAGER_REGISTRY_SLOT_TAG";
    string internal constant BRIDGE_TAG = "STARKGATE_MANAGER_BRIDGE_SLOT_TAG";
    event TokenEnrolled(address indexed token, address indexed sender);
    event ExistingBridgeAdded(address indexed token, address indexed bridge);
    event TokenDeactivated(address indexed token, address indexed sender);
    event TokenBlocked(address indexed token, address indexed sender);

    function getRegistry() external view returns (address) {
        return registry();
    }

    // Storage Getters.
    // TODO : add doc.
    function registry() internal view returns (address) {
        return NamedStorage.getAddressValue(REGISTRY_TAG);
    }

    function bridge() internal view returns (address) {
        return NamedStorage.getAddressValue(BRIDGE_TAG);
    }

    // Storage Setters.
    function setRegistry(address contract_) internal {
        NamedStorage.setAddressValueOnce(REGISTRY_TAG, contract_);
    }

    function setBridge(address contract_) internal {
        NamedStorage.setAddressValueOnce(BRIDGE_TAG, contract_);
    }

    function identify() external pure override returns (string memory) {
        return "StarkWare_StarkgateManager_2.0_1";
    }

    /*
      Initializes the contract.
    */
    function initializeContractState(bytes calldata data) internal override {
        (address registry_, address bridge_) = abi.decode(data, (address, address));
        setRegistry(registry_);
        setBridge(bridge_);
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
        (address registry_, address bridge_) = abi.decode(data, (address, address));
        require(registry_.isContract(), "INVALID_REGISTRY_CONTRACT_ADDRESS");
        require(bridge_.isContract(), "INVALID_BRIDGE_CONTRACT_ADDRESS");
    }

    function addExistingBridge(address token, address bridge_) external onlyTokenAdmin {
        IStarkgateRegistry(registry()).enlistToken(token, bridge_);
        emit ExistingBridgeAdded(token, bridge_);
    }

    /**
      Deactivates bridging of a specific token.
      A deactivated token is blocked for deposits and cannot be re-deployed.
      Note: Only serviced tokens can be deactivated. In order to block an unserviced tokens
      see 'blockToken'.
    */
    function deactivateToken(address token) external onlyTokenAdmin {
        IStarkgateRegistry registryContract = IStarkgateRegistry(registry());
        address current_bridge = registryContract.getBridge(token);

        require(current_bridge != address(0), "TOKEN_NOT_ENROLLED");
        if (current_bridge == BLOCKED_TOKEN) {
            string memory revertMsg = registryContract.getWithdrawalBridges(token).length == 0
                ? "TOKEN_ALREADY_BLOCKED"
                : "TOKEN_ALREADY_DEACTIVATED";
            revert(revertMsg);
        }
        emit TokenDeactivated(token, msg.sender);
        registryContract.blockToken(token);
        if (current_bridge == bridge()) {
            IStarkgateBridge(bridge()).deactivate(token);
        }
    }

    /**
      Block token from being bridged.
      A blocked token cannot be deployed.
      Note: Only an unserviced token can be blocked. In order to deactivate a serviced tokens
        see 'deactivateToken'.
    */
    function blockToken(address token) external onlyTokenAdmin {
        IStarkgateRegistry registryContract = IStarkgateRegistry(registry());
        address current_bridge = registryContract.getBridge(token);
        if (current_bridge == address(0)) {
            emit TokenBlocked(token, msg.sender);
            registryContract.blockToken(token);
        } else if (current_bridge == BLOCKED_TOKEN) {
            string memory revertMsg = registryContract.getWithdrawalBridges(token).length == 0
                ? "TOKEN_ALREADY_BLOCKED"
                : "CANNOT_BLOCK_DEACTIVATED_TOKEN";
            revert(revertMsg);
        } else {
            revert("CANNOT_BLOCK_TOKEN_IN_SERVICE");
        }
    }

    function enrollTokenBridge(address token) external payable {
        IStarkgateRegistry registryContract = IStarkgateRegistry(registry());
        require(registryContract.getBridge(token) != BLOCKED_TOKEN, "CANNOT_DEPLOY_BRIDGE");
        emit TokenEnrolled(token, msg.sender);
        registryContract.enlistToken(token, bridge());
        IStarkgateBridge(bridge()).enrollToken{value: msg.value}(token);
    }
}
