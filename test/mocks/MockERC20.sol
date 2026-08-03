// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Takes feeBps on every transfer, burned to address(0xfee).
contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) MockERC20("FoT", "FOT", 18) {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0xfee), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
