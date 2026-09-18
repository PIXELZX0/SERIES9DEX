// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDexRegistry} from "../interfaces/IDexRegistry.sol";

/// @notice The emergency stop lives on `DexRegistry` and every pool and pair
/// reads it from there. Pools have no owner, no upgrade path and no storage
/// for a flag of their own, but they already hold the registry address as an
/// immutable — so routing the check through it needs no change to how a pool
/// is deployed, and applies to pools that already exist.
///
/// Only entry points consult this. Withdrawing liquidity, closing a position
/// and cancelling an order are never gated, so a pause cannot trap funds.
library Pausing {
    error Paused();

    function requireNotPaused(address registry) internal view {
        if (IDexRegistry(registry).paused()) revert Paused();
    }
}
