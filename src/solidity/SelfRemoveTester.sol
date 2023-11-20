// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "starkware/solidity/interfaces/Identity.sol";
import "starkware/solidity/interfaces/ProxySupport.sol";
import "src/solidity/IStarkgateService.sol";
import "src/solidity/IStarkgateRegistry.sol";

contract SelfRemoveTester is IStarkgateService, Identity, ProxySupport {
    function identify() external pure virtual returns (string memory) {
        return "SelfRemoveTester";
    }

    function validateInitData(bytes calldata data) internal view virtual override {
        require(data.length == 0, "ILLEGAL_DATA_SIZE");
    }

    function initializeContractState(bytes calldata data) internal override {}

    function isInitialized() internal view virtual override returns (bool) {
        return true;
    }

    /*
      No processing needed, as there are no sub-contracts to this contract.
    */
    function processSubContractAddresses(bytes calldata subContractAddresses) internal override {}

    function numOfSubContracts() internal pure override returns (uint256) {
        return 0;
    }

    function isServicingToken(address) public pure returns (bool) {
        return true;
    }

    function callSelfRemoveInTheRegistry(address token, address registry) external {
        IStarkgateRegistry(registry).selfRemove(token);
    }
}
