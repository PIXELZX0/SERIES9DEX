// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice One Pair contract per token pair: owns pool creation, the
/// on-chain orderbook for that pair.
/// Replaces the former bytes32 pairId scheme entirely — a Pair's own
/// address is the identifier.
interface IPair {
    enum Side {
        BUY,
        SELL
    }

    enum Status {
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    function base() external view returns (address);
    function quote() external view returns (address);
    function isSpotPool(address pool) external view returns (bool);

    /// @notice Called by a spot pool of this pair right after its own swap.
    function matchFromPool(uint256 maxFills) external;
    /// @notice Permissionless keeper entry point.
    function matchOrders(uint256 maxFills) external;

    function bestBid() external view returns (uint256 priceX18, uint256 totalBase);
    function bestAsk() external view returns (uint256 priceX18, uint256 totalBase);
}
