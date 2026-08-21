// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Creator-chosen risk parameters for a perp pool, fixed at creation.
struct PerpParams {
    uint32 maxLeverageX; // e.g. 10 => 10x
    uint32 maintenanceMarginBps; // of position notional at mark
    uint32 liquidationFeeBps; // of remaining margin, paid to liquidator
    uint32 maxUtilizationBps; // per-side open notional cap vs LP equity
    uint64 fundingCoeffPpmPerHour; // funding rate at 100% imbalance
}

interface IPerpPool {
    function pairId() external view returns (bytes32);
    function quoteToken() external view returns (address);
    function baseToken() external view returns (address);
    function lpFeeRatePpm() external view returns (uint32);
    function addLiquidity(uint256 quoteIn, uint256 minShares, address to) external returns (uint256 shares);
    function removeLiquidity(uint256 shares, uint256 minQuoteOut, address to) external returns (uint256 quoteOut);
}
