// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISpotPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function pair() external view returns (address);
    function lpFeeRatePpm() external view returns (uint32);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint64 blockTimestampLast);
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
    function getAmountIn(address tokenIn, uint256 amountOut) external view returns (uint256 amountIn);
    function spotPriceX36() external view returns (uint256);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function ORACLE_EPOCH() external view returns (uint256);
    function observe(uint256 epoch, uint256 hint)
        external
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint256 inverseLiquidityCumulative,
            uint256 reserve0At,
            uint256 reserve1At
        );
    function enableOracle() external;
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external returns (uint256 liquidity, uint256 used0, uint256 used1);
    function removeLiquidity(uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 amount0, uint256 amount1);
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
    function swapFromPair(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
}
