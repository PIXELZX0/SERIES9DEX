// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice UniswapV2Pair's swap accounting (balance-based, K check with the
/// fee taken from the input) with a configurable fee, so one mock stands in
/// for both Uniswap V2 (3000 ppm) and PancakeSwap V2 (2500 ppm).
contract MockUniswapV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable feePpm;

    uint112 internal reserve0;
    uint112 internal reserve1;

    constructor(address tokenA, address tokenB, uint256 feePpm_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        feePpm = feePpm_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    /// @notice Stand-in for `mint`: take whatever was transferred in as
    /// liquidity and record it.
    function sync() external {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "INSUFFICIENT_LIQUIDITY");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        uint256 adjusted0 = balance0 * 1e6 - amount0In * feePpm;
        uint256 adjusted1 = balance1 * 1e6 - amount1In * feePpm;
        require(adjusted0 * adjusted1 >= uint256(reserve0) * reserve1 * 1e12, "K");

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}
