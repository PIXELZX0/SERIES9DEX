// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Stand-in for a real Pair when isolating SpotPool's auto-match
/// hook: records calls, can be told to revert to prove swap/hook failure
/// isolation.
contract MockPair {
    bool public revertOnMatch;
    uint256 public matchCalls;
    uint256 public lastMaxFills;

    error MatchReverted();

    function setRevertOnMatch(bool value) external {
        revertOnMatch = value;
    }

    function matchFromPool(uint256 maxFills) external {
        if (revertOnMatch) revert MatchReverted();
        matchCalls++;
        lastMaxFills = maxFills;
    }
}
