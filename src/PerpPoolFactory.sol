// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PerpPool} from "./PerpPool.sol";
import {PerpParams} from "./interfaces/IPerpPool.sol";

/// @notice Deploys PerpPool bytecode on behalf of the registry; see
/// SpotPoolFactory for rationale.
contract PerpPoolFactory {
    address public immutable registry;

    error OnlyRegistry();

    constructor(address registry_) {
        registry = registry_;
    }

    function deploy(
        address treasury,
        address spotPool,
        address baseToken,
        address quoteToken,
        uint32 lpFeeRatePpm,
        bytes32 pairId,
        PerpParams calldata params
    ) external returns (address pool) {
        if (msg.sender != registry) revert OnlyRegistry();
        pool = address(new PerpPool(registry, treasury, spotPool, baseToken, quoteToken, lpFeeRatePpm, pairId, params));
    }
}
