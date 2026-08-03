// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Phase-1 stand-in for the real Orderbook: records calls, can be
/// told to revert to prove swap/hook failure isolation.
contract MockOrderbook {
    bool public revertOnMatch;
    uint256 public matchCalls;
    bytes32 public lastPairId;
    uint256 public lastMaxFills;
    mapping(bytes32 => bool) public bookInitialized;

    error MatchReverted();

    function setRevertOnMatch(bool value) external {
        revertOnMatch = value;
    }

    function initBook(bytes32 pairId, address, address, uint256) external {
        bookInitialized[pairId] = true;
    }

    function matchFromPool(bytes32 pairId, uint256 maxFills) external {
        if (revertOnMatch) revert MatchReverted();
        matchCalls++;
        lastPairId = pairId;
        lastMaxFills = maxFills;
    }
}
