// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISpotPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function pairId() external view returns (bytes32);
    function lpFeeRatePpm() external view returns (uint32);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint64 blockTimestampLast);
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
    function spotPriceX18() external view returns (uint256);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
    function swapFromOrderbook(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
}
