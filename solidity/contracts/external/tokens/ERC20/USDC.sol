// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { AccessControl } from "OpenZeppelin/openzeppelin-contracts@4.8.0/contracts/access/AccessControl.sol";
import { ERC20 } from "OpenZeppelin/openzeppelin-contracts@4.8.0/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "OpenZeppelin/openzeppelin-contracts@4.8.0/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Pausable } from "OpenZeppelin/openzeppelin-contracts@4.8.0/contracts/security/Pausable.sol";

/// @custom:security-contact security@paradex.trade
contract USDCToken is ERC20, ERC20Burnable, Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC20("USDC", "USDC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint amount)
        internal
        whenNotPaused
        override
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `6`, a balance of `5000005` tokens should
     * be displayed to a user as `5.000005` (`5000005 / 10 ** 6`).
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}