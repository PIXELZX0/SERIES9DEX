// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A UniswapV3 pool with one full-range position: constant liquidity
/// `L`, so price moves exactly as in V3 inside a single tick range. Enough to
/// exercise the callback protocol and sqrt-price math without tick crossing.
///
/// `pancake` switches the callback name and makes `slot0` return a uint32
/// `feeProtocol` above 255, like PancakeSwap V3, which a Uniswap-shaped
/// decoder would reject.
contract MockUniswapV3Pool {
    uint256 internal constant Q96 = 1 << 96;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    bool public immutable pancake;
    uint128 public immutable liquidity;

    uint160 internal sqrtPriceX96;

    constructor(address tokenA, address tokenB, uint24 fee_, uint128 liquidity_, uint160 sqrtPriceX96_, bool pancake_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        liquidity = liquidity_;
        sqrtPriceX96 = sqrtPriceX96_;
        pancake = pancake_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, 0, 0, 1, 1, pancake ? 0x10000 : 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-in only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 net = amountIn * (1e6 - fee) / 1e6;
        uint256 lq = uint256(liquidity) << 96;
        uint256 price = sqrtPriceX96;
        uint256 amountOut;

        if (zeroForOne) {
            uint256 next = Math.mulDiv(lq, price, lq + net * price, Math.Rounding.Ceil);
            amountOut = Math.mulDiv(liquidity, price - next, Q96);
            sqrtPriceX96 = uint160(next);
            IERC20(token1).transfer(recipient, amountOut);
            (amount0, amount1) = (int256(amountIn), -int256(amountOut));
        } else {
            uint256 next = price + Math.mulDiv(net, Q96, liquidity);
            amountOut = Math.mulDiv(lq, next - price, next) / price;
            sqrtPriceX96 = uint160(next);
            IERC20(token0).transfer(recipient, amountOut);
            (amount0, amount1) = (-int256(amountOut), int256(amountIn));
        }

        address tokenIn = zeroForOne ? token0 : token1;
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        if (pancake) IV3SwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        else IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}
