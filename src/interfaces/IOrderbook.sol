// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IOrderbook {
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

    function initBook(bytes32 pairId, address base, address quote, uint256 tickSize) external;
    function matchFromPool(bytes32 pairId, uint256 maxFills) external;
    function matchOrders(bytes32 pairId, address pool, uint256 maxFills) external;
    function bestBid(bytes32 pairId) external view returns (uint256 priceX18, uint256 totalBase);
    function bestAsk(bytes32 pairId) external view returns (uint256 priceX18, uint256 totalBase);
}
