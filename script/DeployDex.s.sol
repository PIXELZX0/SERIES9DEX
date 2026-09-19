// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PerpPoolFactory} from "../src/PerpPoolFactory.sol";
import {DexPositionManager} from "../src/DexPositionManager.sol";
import {DexRouter} from "../src/DexRouter.sol";

/// @notice Deploys the Series9DEX stack with a Safe multisig as the final owner.
///
/// Flow:
///   1. ProtocolTreasury proxy (Safe as owner from the start)
///   2. DexRegistry proxy (deployer as temporary owner for wiring)
///   3. Pool factories (immutable, take the registry proxy address)
///   4. Wire factories into the registry
///   5. Transfer registry ownership to the Safe
///
/// Pairs (each a CREATE2-deployed `Pair` contract) and pools are not created
/// here — they're created later at runtime via `DexRegistry.createPair` and
/// `Pair.createSpotPool`/`createPerpPool`.
///
/// Usage:
///   PRIVATE_KEY=0x... SAFE_ADDRESS=0x... forge script script/DeployDex.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract DeployDex is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        // Optional. The guardian can pause and nothing else; leaving it unset
        // means only the Safe can, which is slower in an incident.
        address guardian = vm.envOr("GUARDIAN_ADDRESS", address(0));
        // Fee withdrawals are never urgent, so a delay in front of them costs
        // almost nothing and turns a key compromise from an instant drain into
        // something observable and cancellable. The timelock can change this
        // later, through itself.
        uint256 timelockDelay = vm.envOr("TREASURY_TIMELOCK_DELAY", uint256(48 hours));
        address deployer = vm.addr(deployerPrivateKey);

        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(safeAddress != deployer, "SAFE_ADDRESS must differ from deployer");

        console.log("Deployer (temporary):", deployer);
        console.log("Safe Owner (permanent):", safeAddress);
        console.log("Guardian (pause-only):", guardian);

        vm.startBroadcast(deployerPrivateKey);

        // --- Treasury timelock ---
        // Proposer is the Safe. Execution is open (`address(0)` in executors),
        // so once the delay has run anyone can push the transaction through and
        // the Safe cannot be censored out of its own funds.
        //
        // The guardian is added as a canceller: a compromised Safe can queue a
        // drain, but the fast key that already exists to pause the system can
        // kill it before the delay expires. Role changes are themselves subject
        // to the delay, because the timelock is left self-administered, so that
        // canceller cannot be stripped faster than it can act.
        address[] memory proposers = new address[](1);
        proposers[0] = safeAddress;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController treasuryTimelock = new TimelockController(timelockDelay, proposers, executors, deployer);
        if (guardian != address(0)) {
            treasuryTimelock.grantRole(treasuryTimelock.CANCELLER_ROLE(), guardian);
        }
        treasuryTimelock.renounceRole(treasuryTimelock.DEFAULT_ADMIN_ROLE(), deployer);

        // --- Treasury (owned by the timelock, never by the Safe directly) ---
        ProtocolTreasury treasuryImplementation = new ProtocolTreasury();
        ProtocolTreasury treasury = ProtocolTreasury(
            address(
                new ERC1967Proxy(
                    address(treasuryImplementation),
                    abi.encodeCall(ProtocolTreasury.initialize, (address(treasuryTimelock)))
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
        SpotPoolFactory spotPoolFactory = new SpotPoolFactory(address(registry));
        PerpPoolFactory perpPoolFactory = new PerpPoolFactory(address(registry));
        // Periphery: the registry does not need to know about it, LPs opt in.
        DexPositionManager positionManager = new DexPositionManager(address(registry));
        DexRouter router = new DexRouter(address(registry));

        // --- Wire, then hand over ---
        registry.setFactories(address(spotPoolFactory), address(perpPoolFactory));
        if (guardian != address(0)) registry.setGuardian(guardian);
        registry.transferOwnership(safeAddress);

        vm.stopBroadcast();

        console.log("\n=== Deployed Addresses ===");
        console.log("ProtocolTreasury Implementation:", address(treasuryImplementation));
        console.log("ProtocolTreasury Proxy:", address(treasury));
        console.log("Treasury Timelock:", address(treasuryTimelock));
        console.log("  delay (seconds):", timelockDelay);
        console.log("DexRegistry Implementation:", address(registryImplementation));
        console.log("DexRegistry Proxy:", address(registry));
        console.log("SpotPoolFactory:", address(spotPoolFactory));
        console.log("PerpPoolFactory:", address(perpPoolFactory));
        console.log("DexPositionManager:", address(positionManager));
        console.log("DexRouter:", address(router));

        // Labeled record for CI: verification and post-deploy assertions need to
        // know which proxy is which, and the broadcast file only says
        // "ERC1967Proxy" twice.
        _writeDeploymentJson(
            deployer,
            safeAddress,
            guardian,
            address(treasuryTimelock),
            address(treasuryImplementation),
            address(treasury),
            address(registryImplementation),
            address(registry),
            address(spotPoolFactory),
            address(perpPoolFactory),
            address(positionManager),
            address(router)
        );
    }

    function _writeDeploymentJson(
        address deployer,
        address safeAddress,
        address guardian,
        address treasuryTimelock,
        address treasuryImplementation,
        address treasury,
        address registryImplementation,
        address registry,
        address spotPoolFactory,
        address perpPoolFactory,
        address positionManager,
        address router
    ) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "safeOwner", safeAddress);
        vm.serializeAddress(obj, "guardian", guardian);
        vm.serializeAddress(obj, "treasuryTimelock", treasuryTimelock);
        vm.serializeAddress(obj, "protocolTreasuryImpl", treasuryImplementation);
        vm.serializeAddress(obj, "protocolTreasuryProxy", treasury);
        vm.serializeAddress(obj, "dexRegistryImpl", registryImplementation);
        vm.serializeAddress(obj, "dexRegistryProxy", registry);
        vm.serializeAddress(obj, "spotPoolFactory", spotPoolFactory);
        vm.serializeAddress(obj, "perpPoolFactory", perpPoolFactory);
        vm.serializeAddress(obj, "dexPositionManager", positionManager);
        string memory out = vm.serializeAddress(obj, "dexRouter", router);

        vm.createDir("deployments", true);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
