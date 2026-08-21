// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PerpPoolFactory} from "../src/PerpPoolFactory.sol";
import {Orderbook} from "../src/Orderbook.sol";
import {DexPositionManager} from "../src/DexPositionManager.sol";

/// @notice Deploys the Series9DEX stack with a Safe multisig as the final owner.
///
/// Flow:
///   1. ProtocolTreasury proxy (Safe as owner from the start)
///   2. DexRegistry proxy (deployer as temporary owner for wiring)
///   3. Orderbook + factories (immutable, take the registry proxy address)
///   4. Wire orderbook + factories into the registry
///   5. Transfer registry ownership to the Safe
///
/// Usage:
///   PRIVATE_KEY=0x... SAFE_ADDRESS=0x... forge script script/DeployDex.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract DeployDex is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(safeAddress != deployer, "SAFE_ADDRESS must differ from deployer");

        console.log("Deployer (temporary):", deployer);
        console.log("Safe Owner (permanent):", safeAddress);

        vm.startBroadcast(deployerPrivateKey);

        // --- Treasury (Safe-owned from day one) ---
        ProtocolTreasury treasuryImplementation = new ProtocolTreasury();
        ProtocolTreasury treasury = ProtocolTreasury(
            address(
                new ERC1967Proxy(
                    address(treasuryImplementation), abi.encodeCall(ProtocolTreasury.initialize, (safeAddress))
                )
            )
        );

        // --- Registry proxy (deployer temporarily owns for wiring) ---
        DexRegistry registryImplementation = new DexRegistry();
        DexRegistry registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(DexRegistry.initialize, (deployer, address(treasury)))
                )
            )
        );

        // --- Immutable singletons (need the registry proxy address) ---
        Orderbook orderbook = new Orderbook(address(registry));
        SpotPoolFactory spotPoolFactory = new SpotPoolFactory(address(registry));
        PerpPoolFactory perpPoolFactory = new PerpPoolFactory(address(registry));
        // Periphery: the registry does not need to know about it, LPs opt in.
        DexPositionManager positionManager = new DexPositionManager(address(registry));

        // --- Wire, then hand over ---
        registry.setOrderbook(address(orderbook));
        registry.setFactories(address(spotPoolFactory), address(perpPoolFactory));
        registry.transferOwnership(safeAddress);

        vm.stopBroadcast();

        console.log("\n=== Deployed Addresses ===");
        console.log("ProtocolTreasury Implementation:", address(treasuryImplementation));
        console.log("ProtocolTreasury Proxy:", address(treasury));
        console.log("DexRegistry Implementation:", address(registryImplementation));
        console.log("DexRegistry Proxy:", address(registry));
        console.log("Orderbook:", address(orderbook));
        console.log("SpotPoolFactory:", address(spotPoolFactory));
        console.log("PerpPoolFactory:", address(perpPoolFactory));
        console.log("DexPositionManager:", address(positionManager));

        // Labeled record for CI: verification and post-deploy assertions need to
        // know which proxy is which, and the broadcast file only says
        // "ERC1967Proxy" twice.
        _writeDeploymentJson(
            deployer,
            safeAddress,
            address(treasuryImplementation),
            address(treasury),
            address(registryImplementation),
            address(registry),
            address(orderbook),
            address(spotPoolFactory),
            address(perpPoolFactory),
            address(positionManager)
        );
    }

    function _writeDeploymentJson(
        address deployer,
        address safeAddress,
        address treasuryImplementation,
        address treasury,
        address registryImplementation,
        address registry,
        address orderbook,
        address spotPoolFactory,
        address perpPoolFactory,
        address positionManager
    ) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "safeOwner", safeAddress);
        vm.serializeAddress(obj, "protocolTreasuryImpl", treasuryImplementation);
        vm.serializeAddress(obj, "protocolTreasuryProxy", treasury);
        vm.serializeAddress(obj, "dexRegistryImpl", registryImplementation);
        vm.serializeAddress(obj, "dexRegistryProxy", registry);
        vm.serializeAddress(obj, "orderbook", orderbook);
        vm.serializeAddress(obj, "spotPoolFactory", spotPoolFactory);
        vm.serializeAddress(obj, "perpPoolFactory", perpPoolFactory);
        string memory out = vm.serializeAddress(obj, "dexPositionManager", positionManager);

        vm.createDir("deployments", true);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
