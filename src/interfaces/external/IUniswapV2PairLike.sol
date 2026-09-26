// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice The subset of a UniswapV2 pair the balancer touches. PancakeSwap V2
/// and most V2 forks expose the same ABI; only the fee differs (Uniswap V2
/// 0.30%, PancakeSwap V2 0.25%), and the pair does not report it, so the
/// balancer stores it per venue.
interface IUniswapV2PairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
