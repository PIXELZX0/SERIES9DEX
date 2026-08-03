// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IDexRegistry {
    function treasury() external view returns (address);
    function orderbook() external view returns (address);
    function maxLpFeeRatePpm() external view returns (uint32);
    function isSpotPool(address pool) external view returns (bool);
    function poolPairId(address pool) external view returns (bytes32);
    function getSpotPools(bytes32 pairId) external view returns (address[] memory);
    function getPerpPools(bytes32 pairId) external view returns (address[] memory);
}
