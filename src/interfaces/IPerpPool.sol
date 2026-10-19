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

/// @notice Lifecycle of an LP deposit or withdrawal request.
enum LpStatus {
    NONE,
    PENDING,
    EXECUTED,
    REFUNDED,
    CANCELLED
}

interface IPerpPool {
    function pair() external view returns (address);
    function quoteToken() external view returns (address);
    function baseToken() external view returns (address);
    function lpFeeRatePpm() external view returns (uint32);
    function requestDeposit(
        uint256 quoteIn,
        uint256 minShares,
        address receiver,
        address refundTo,
        uint256 executionFee
    ) external returns (uint256 requestId);
    function requestWithdraw(
        uint256 shares,
        uint256 minQuoteOut,
        address receiver,
        address refundTo,
        uint256 executionFee
    ) external returns (uint256 requestId);
    function executeLp(uint256 requestId, uint256[3] calldata hints) external;
    function lpRequestOutcome(uint256 requestId)
        external
        view
        returns (LpStatus status, bool isDeposit, uint256 amount, uint256 out);
}
