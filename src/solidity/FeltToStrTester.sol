// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;
import "src/solidity/utils/Felt252.sol";

contract FeltToStrTester {
    using Felt252 for string;

    function testSafeStrToFelt(string memory string_) public pure returns (uint256) {
        return string_.safeToFelt();
    }

    function testStrToFelt(string memory string_) public pure returns (uint256) {
        return string_.toFelt();
    }
}
