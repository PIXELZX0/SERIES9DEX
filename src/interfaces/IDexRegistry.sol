// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IDexRegistry {
    function treasury() external view returns (address);
    function spotPoolFactory() external view returns (address);
    function perpPoolFactory() external view returns (address);
    function isSpotPool(address pool) external view returns (bool);
    function isPair(address pair) external view returns (bool);
    function paused() external view returns (bool);
    function pauseWindow() external view returns (bool isPaused, uint64 pausedAt, uint64 unpausedAt);
    function poolToPair(address pool) external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address);
    function predictPairAddress(address tokenX, address tokenY) external view returns (address);
    function registerPool(address pool, bool isSpot) external;
}
