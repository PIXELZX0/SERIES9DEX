// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @notice Fee model from DEX.md §6: total fee = amount * lpFeeRatePpm / 1e6,
/// protocol cut = 0.1% of that fee, remainder to LPs.
///
/// Both steps round up. Rounding down let any trade small enough to floor the
/// fee to zero pay nothing at all, so splitting one trade into many skipped
/// the fee; and it zeroed the protocol cut on every trade whose fee was under
/// 1000 units — every WBTC swap below 0.1 BTC on a 0.01% pool. Rounding up
/// moves at most one unit per trade, always away from the trader.
library FeeSplit {
    uint256 internal constant PPM = 1e6;
    uint256 internal constant PROTOCOL_CUT_DIVISOR = 1000;

    function split(uint256 amount, uint32 lpFeeRatePpm)
        internal
        pure
        returns (uint256 totalFee, uint256 protocolFee, uint256 lpFee)
    {
        totalFee = Math.mulDiv(amount, lpFeeRatePpm, PPM, Math.Rounding.Ceil);
        (protocolFee, lpFee) = splitFee(totalFee);
    }

    /// @dev Split a fee that was already computed (or capped) elsewhere, so
    /// callers never have to restate the protocol cut by hand.
    function splitFee(uint256 totalFee) internal pure returns (uint256 protocolFee, uint256 lpFee) {
        protocolFee = Math.ceilDiv(totalFee, PROTOCOL_CUT_DIVISOR);
        lpFee = totalFee - protocolFee;
    }
}
