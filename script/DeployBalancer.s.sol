// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PriceBalancer} from "../src/PriceBalancer.sol";

/// @notice Deploys `PriceBalancer` against an existing DexRegistry.
///
/// The owner is set in the constructor, so there is no pending handoff to
/// finish. Venues are not registered here: the venue list is the balancer's
/// security boundary, so the owner (the Safe) adds them itself with
/// `setVenue` after checking each address (docs/BALANCER.md §4).
///
/// Usage:
///   PRIVATE_KEY=0x... DEX_REGISTRY=0x... BALANCER_OWNER=0x... \
///   KEEPER_ADDRESS=0x... forge script script/DeployBalancer.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract DeployBalancer is Script {
    function run() external returns (PriceBalancer balancer) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registry = vm.envAddress("DEX_REGISTRY");
        address owner = vm.envAddress("BALANCER_OWNER");
        // Optional. The keeper's hot key; it can trigger rebalances and
        // nothing else. The owner can add or replace it later.
        address keeper = vm.envOr("KEEPER_ADDRESS", address(0));

        require(registry.code.length > 0, "DEX_REGISTRY has no code");
        require(owner != address(0), "BALANCER_OWNER required");
        require(keeper != owner, "KEEPER_ADDRESS must differ from BALANCER_OWNER");

        vm.startBroadcast(deployerPrivateKey);
        balancer = new PriceBalancer(registry, owner, keeper);
        vm.stopBroadcast();

        console.log("PriceBalancer:", address(balancer));
        console.log("Owner:", owner);
        console.log("Keeper:", keeper);
    }
}
