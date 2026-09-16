// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PerpPool} from "./PerpPool.sol";
import {PerpParams} from "./interfaces/IPerpPool.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";

/// @notice Deploys PerpPool bytecode on behalf of a Pair; see
/// SpotPoolFactory for rationale.
contract PerpPoolFactory {
    address public immutable registry;

    error NotPair();

    constructor(address registry_) {
        registry = registry_;
    }

    function deploy(
        address treasury,
        address spotPool,
        address baseToken,
        address quoteToken,
        uint32 lpFeeRatePpm,
        PerpParams calldata params
    ) external returns (address pool) {
        if (!IDexRegistry(registry).isPair(msg.sender)) revert NotPair();
        pool = address(new PerpPool(registry, treasury, spotPool, baseToken, quoteToken, lpFeeRatePpm, msg.sender, params));
    }
}
