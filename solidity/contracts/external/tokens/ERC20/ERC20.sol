// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "./IERC20.sol";
import "./IERC20Metadata.sol";

abstract contract ERC20 is IERC20, IERC20Metadata {
    mapping(address => uint256) internal _balances;

    mapping(address => mapping(address => uint256)) internal _allowances;

    uint256 internal _totalSupply;
    string internal name_;
    string internal symbol_;
    uint8 internal decimals_;

    function name() external view override returns (string memory) {
        return name_;
    }

    function symbol() external view override returns (string memory) {
        return symbol_;
    }

    function decimals() external view override returns (uint8) {
        return decimals_;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 sender_allowance = _allowances[sender][msg.sender];
        require(sender_allowance >= amount, "ERC20: transfer exceeds allowance");
        _approve(sender, msg.sender, sender_allowance - amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        uint256 spender_allowance = _allowances[msg.sender][spender];
        require(spender_allowance + addedValue >= spender_allowance, "ERC20: Overflow");
        _approve(msg.sender, spender, spender_allowance + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 sender_allowance = _allowances[msg.sender][spender];
        require(sender_allowance >= subtractedValue, "ERC20: transfer exceeds allowance");
        _approve(msg.sender, spender, sender_allowance - subtractedValue);
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        uint256 sender_balance = _balances[sender];
        uint256 recipient_balance = _balances[recipient];
        require(sender_balance >= amount, "ERC20: transfer amount exceeds balance");
        require(recipient_balance + amount >= recipient_balance, "ERC20: Overflow");
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");
        uint256 _total = _totalSupply;
        require(_total + amount >= _total, "ERC20: Overflow");
        _totalSupply = _total + amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 value) internal {
        require(account != address(0), "ERC20: burn from the zero address");
        uint256 current_balance = _balances[account];
        require(current_balance >= value, "ERC20: burn amount exceeds balance");
        _balances[account] = current_balance - value;
        _totalSupply -= value;
        emit Transfer(account, address(0), value);
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _burnFrom(address account, uint256 amount) internal {
        _burn(account, amount);
        uint256 current_allowance = _allowances[account][msg.sender];
        require(current_allowance >= amount, "ERC20: burn amount exceeds allowance");
        _approve(account, msg.sender, current_allowance - amount);
    }
}
