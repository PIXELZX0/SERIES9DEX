// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice The subset of a UniswapV3 pool the balancer touches. PancakeSwap V3
/// has the same `swap` ABI but calls back `pancakeV3SwapCallback` instead of
/// `uniswapV3SwapCallback`, and its `slot0` packs `feeProtocol` as a uint32
/// where Uniswap uses a uint8. Declaring only the first return value keeps one
/// interface valid for both: the decoder reads the leading word and ignores
/// the rest, so it never range-checks the field that differs.
interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
