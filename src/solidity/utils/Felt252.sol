// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.0;

import "starkware/cairo/eth/CairoConstants.sol";

/**
 * @dev String to felt functions.
 *
 * These functions convert string to felt (felt252) uint value.
 * The felt value is the Starknet short string representation.
 *
 * As felt value is bound by the field prime, it limits the length of the represented string.
 * For felt252 the limit is 31 characters.
 *
 * `safeToFelt()` converts to felt as many as 31 characters of the string.
 * i.e. for a long string: safeToFelt(string) == toFelt(string[:31]).
 *
 * When `toFelt()` accepts a long string - it fails and the call revert.
 */
library Felt252 {
    uint256 constant MAX_SHORT_STRING_LENGTH = 31;

    /**
      Convert a string to felt uint value.
      Reverts if the string is longer than 31 characters.
     */
    function toFelt(string memory shortString) internal pure returns (uint256) {
        uint256 length = strlen(shortString);
        return strToFelt(shortString, length);
    }

    /**
      Safely convert a string to felt uint value.
      For a string up to 31 characters, behaves identically ot `toFelt`.
      For longer strings, it returns the felt representation of the first 31 characters.
     */
    function safeToFelt(string memory string_) internal pure returns (uint256) {
        uint256 len = min(MAX_SHORT_STRING_LENGTH, strlen(string_));
        return strToFelt(string_, len);
    }

    function strToFelt(string memory string_, uint256 length) private pure returns (uint256) {
        require(length <= MAX_SHORT_STRING_LENGTH, "STRING_TOO_LONG");
        uint256 asUint;

        // As we process only short strings (<=31 chars),
        // we can look no further than the first 32 bytes of the string.
        // We convert first 32 bytes of the string to a uint.
        assembly {
            asUint := mload(add(string_, 32))
        }

        // We shift left the unused bits, so we don't get lsb zero padding.
        // The shift is 8 bits for every unused characters (of the looked at 32 bytes).
        uint256 felt252 = asUint >> (8 * (32 - length));
        return felt252;
    }

    /**
      Returns string length.
     */
    function strlen(string memory string_) private pure returns (uint256) {
        bytes memory bytes_;
        assembly {
            bytes_ := string_
        }
        return bytes_.length;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

library UintFelt252 {
    function isValidL2Address(uint256 l2Address) internal pure returns (bool) {
        return (l2Address != 0 && isFelt(l2Address));
    }

    function isFelt(uint256 maybeFelt) internal pure returns (bool) {
        return (maybeFelt < CairoConstants.FIELD_PRIME);
    }
}
