// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SpotPool} from "./SpotPool.sol";

/// @notice Deploys SpotPool bytecode on behalf of the registry. Keeps pool
/// creation code out of the upgradeable registry (24KB limit + upgrade
/// safety). The registry can be repointed to a new factory to evolve pool
/// code; already-deployed pools stay immutable.
contract SpotPoolFactory {
    address public immutable registry;

    error OnlyRegistry();

    constructor(address registry_) {
        registry = registry_;
    }

    function deploy(
        address orderbook,
        address treasury,
        address token0,
        address token1,
        uint32 lpFeeRatePpm,
        bytes32 pairId
    ) external returns (address pool) {
        if (msg.sender != registry) revert OnlyRegistry();
        pool = address(new SpotPool(registry, orderbook, treasury, token0, token1, lpFeeRatePpm, pairId));
    }
}
