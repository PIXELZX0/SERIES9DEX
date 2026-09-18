// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Fee model from DEX.md §6: total fee = amount * lpFeeRatePpm / 1e6,
/// protocol cut = 0.1% of that fee (floor), remainder to LPs.
library FeeSplit {
    uint256 internal constant PPM = 1e6;
    uint256 internal constant PROTOCOL_CUT_DIVISOR = 1000;

    function split(uint256 amount, uint32 lpFeeRatePpm)
        internal
        pure
        returns (uint256 totalFee, uint256 protocolFee, uint256 lpFee)
    {
        totalFee = amount * lpFeeRatePpm / PPM;
        (protocolFee, lpFee) = splitFee(totalFee);
    }

    /// @dev Split a fee that was already computed (or capped) elsewhere, so
    /// callers never have to restate the protocol cut by hand.
    function splitFee(uint256 totalFee) internal pure returns (uint256 protocolFee, uint256 lpFee) {
        protocolFee = totalFee / PROTOCOL_CUT_DIVISOR;
        lpFee = totalFee - protocolFee;
    }
}
