// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

contract StarknetBridgeConstatns {
    // The selector of the deposit handler in L2.
    uint256 constant DEPOSIT_SELECTOR =
        1285101517810983806491589552491143496277809242732141897358598292095611420389;
    uint256 constant TRANSFER_FROM_STARKNET = 0;
    uint256 constant UINT256_PART_SIZE_BITS = 128;
    uint256 constant UINT256_PART_SIZE = 2**UINT256_PART_SIZE_BITS;
    string constant GOVERNANCE_TAG = "STARKWARE_DEFAULT_GOVERNANCE_INFO";
}
