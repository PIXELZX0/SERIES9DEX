// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library PairKey {
    error IdenticalTokens();
    error ZeroToken();

    function sort(address tokenX, address tokenY) internal pure returns (address token0, address token1) {
        if (tokenX == tokenY) revert IdenticalTokens();
        if (tokenX == address(0) || tokenY == address(0)) revert ZeroToken();
        (token0, token1) = tokenX < tokenY ? (tokenX, tokenY) : (tokenY, tokenX);
    }

    /// @dev Assumes token0 < token1 (use sort first). Internal lookup/CREATE2
    /// salt key only — `DexRegistry`'s deployed `Pair` address is the actual
    /// pair identifier now, not this hash.
    function pairId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1));
    }
}
