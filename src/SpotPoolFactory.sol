// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SpotPool} from "./SpotPool.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";

/// @notice Deploys SpotPool bytecode on behalf of a Pair. Keeps pool
/// creation code out of the upgradeable registry (24KB limit + upgrade
/// safety). The registry can be repointed to a new factory to evolve pool
/// code; already-deployed pools stay immutable.
contract SpotPoolFactory {
    address public immutable registry;

    error NotPair();

    constructor(address registry_) {
        registry = registry_;
    }

    function deploy(address treasury, address token0, address token1, uint32 lpFeeRatePpm)
        external
        returns (address pool)
    {
        if (!IDexRegistry(registry).isPair(msg.sender)) revert NotPair();
        pool = address(new SpotPool(registry, msg.sender, treasury, token0, token1, lpFeeRatePpm));
    }
}
