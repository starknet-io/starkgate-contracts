// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.8.20;

import "src/solidity/LegacyBridge.sol";

contract StarknetERC20Bridge is LegacyBridge {
    function identify() external pure override returns (string memory) {
        return "StarkWare_StarknetERC20Bridge_2.0_5";
    }
}
