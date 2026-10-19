// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PairKey} from "../src/libraries/PairKey.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexRegistryTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    SpotPoolFactory internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        ProtocolTreasury treasuryImpl = new ProtocolTreasury();
        treasury = ProtocolTreasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(ProtocolTreasury.initialize, (owner))))
        );
        DexRegistry registryImpl = new DexRegistry();
        registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl), abi.encodeCall(DexRegistry.initialize, (owner, address(treasury)))
                )
            )
        );
        factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
    }

    function _sorted() internal view returns (address t0, address t1) {
        (t0, t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
    }

    function _defaultPerpParams() internal pure returns (PerpParams memory) {
        return PerpParams({
            maxLeverageX: 10,
            maintenanceMarginBps: 500,
            liquidationFeeBps: 100,
            maxUtilizationBps: 8000,
            fundingCoeffPpmPerHour: 100
        });
    }

    // -------------------------------------------------------- pair creation

    function testCreatePairAndSpotPool() public {
        address pairAddr = registry.createPair(address(tokenA), address(tokenB));
        (address t0, address t1) = _sorted();
        Pair pair = Pair(pairAddr);
        assertEq(pair.base(), t0);
        assertEq(pair.quote(), t1);
        assertEq(registry.getPair(address(tokenA), address(tokenB)), pairAddr);
        assertTrue(registry.isPair(pairAddr));

        address poolXY = pair.createSpotPool(3000);
        assertEq(registry.poolToPair(poolXY), pairAddr);
        assertEq(SpotPool(poolXY).token0(), t0);
        assertEq(SpotPool(poolXY).token1(), t1);
        assertTrue(registry.isSpotPool(poolXY));

        // Second pool, different fee, same pair.
        address poolXY2 = pair.createSpotPool(5000);
        assertEq(registry.poolToPair(poolXY2), pairAddr);
        assertEq(pair.spotPoolsLength(), 2);
    }

    function testCreatePairDedupReverts() public {
        registry.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(DexRegistry.PairAlreadyExists.selector);
        registry.createPair(address(tokenB), address(tokenA)); // reversed order, same pair
    }

    function testGetPairAndPredictRoundTrip() public {
        address predicted = registry.predictPairAddress(address(tokenA), address(tokenB));
        address pairAddr = registry.createPair(address(tokenA), address(tokenB));
        assertEq(pairAddr, predicted);
        assertEq(registry.getPair(address(tokenA), address(tokenB)), pairAddr);
        assertEq(registry.getPair(address(tokenB), address(tokenA)), pairAddr);
    }

    function testRegisterPoolOnlyPair() public {
        vm.expectRevert(DexRegistry.OnlyPair.selector);
        registry.registerPool(address(1), true);
    }

    function testCreatePairSelfPairReverts() public {
        vm.expectRevert(PairKey.IdenticalTokens.selector);
        registry.createPair(address(tokenA), address(tokenA));
    }

    function testCreatePairZeroTokenReverts() public {
        vm.expectRevert(PairKey.ZeroToken.selector);
        registry.createPair(address(tokenA), address(0));
    }

    function testCreateSpotPoolFeeGuardrail() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        // 1ppm and 10,000ppm boundaries pass, outside them reverts.
        pair.createSpotPool(1);
        pair.createSpotPool(10_000);
        vm.expectRevert(Pair.InvalidFeeRate.selector);
        pair.createSpotPool(0);
        vm.expectRevert(Pair.InvalidFeeRate.selector);
        pair.createSpotPool(10_001);
    }

    function testCreateSpotPoolDuplicateFeeReverts() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        pair.createSpotPool(3000);
        vm.expectRevert(Pair.DuplicateFeeRate.selector);
        pair.createSpotPool(3000);
    }

    function testCreatePerpPoolRequiresFactory() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        address spot = pair.createSpotPool(3000);
        vm.expectRevert(Pair.FactoryNotSet.selector);
        pair.createPerpPool(address(tokenA), spot, 3000, _defaultPerpParams());
    }

    function testCustomTiersAreCappedButCanonicalTiersSurvive() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        // Burn every custom slot with junk rates, the squat this cap exists for.
        for (uint32 i = 0; i < pair.MAX_CUSTOM_SPOT_POOLS(); i++) {
            pair.createSpotPool(1 + i);
        }
        assertEq(pair.customSpotPools(), pair.MAX_CUSTOM_SPOT_POOLS());
        vm.expectRevert(Pair.TooManyCustomSpotPools.selector);
        pair.createSpotPool(2000);

        // The four canonical tiers are still creatable, so the pair lives.
        pair.createSpotPool(pair.FEE_TIER_LOWEST());
        pair.createSpotPool(pair.FEE_TIER_LOW());
        pair.createSpotPool(pair.FEE_TIER_MEDIUM());
        pair.createSpotPool(pair.FEE_TIER_HIGH());
        assertEq(pair.spotPoolsLength(), pair.MAX_CUSTOM_SPOT_POOLS() + 4);
        assertEq(pair.customSpotPools(), pair.MAX_CUSTOM_SPOT_POOLS());
    }

    function testCanonicalTiersNeverConsumeCustomSlots() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        pair.createSpotPool(100);
        pair.createSpotPool(500);
        pair.createSpotPool(3000);
        pair.createSpotPool(10_000);
        assertEq(pair.customSpotPools(), 0);
    }

    function testPlaceOrderNeedsNoPoolForPriceGrid() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        // No tickSize to set and nothing to squat: the grid is a pure
        // function of the price, so an off-grid price is the only rejection.
        vm.expectRevert(Pair.InvalidPrice.selector);
        pair.placeOrder(IPair.Side.SELL, 1e15 + 1, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    // ----------------------------------------------------------------- admin

    function testAdminOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setFactories(address(1), address(0));
    }

    /// The escrow drain in the audit needed exactly this: repoint the
    /// factory, then add a pool to a pair that already held orders. A pair
    /// keeps the factories it was deployed with, so the new one only ever
    /// reaches pairs created after it.
    function testFactoryChangeNeverReachesAnExistingPair() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        SpotPoolFactory replacement = new SpotPoolFactory(address(registry));
        vm.prank(owner);
        registry.setFactories(address(replacement), address(0));

        assertEq(pair.spotPoolFactory(), address(factory));
        address pool = pair.createSpotPool(3000);
        // Deployed by the original factory: CREATE nonce 1 of that factory.
        assertEq(pool, vm.computeCreateAddress(address(factory), 1));

        MockERC20 tokenC = new MockERC20("C", "C", 18);
        Pair later = Pair(registry.createPair(address(tokenA), address(tokenC)));
        assertEq(later.spotPoolFactory(), address(replacement));
    }

    function testCreatePairNeedsASpotFactory() public {
        DexRegistry bare = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(new DexRegistry()), abi.encodeCall(DexRegistry.initialize, (owner, address(treasury)))
                )
            )
        );
        vm.expectRevert(DexRegistry.FactoryNotSet.selector);
        bare.createPair(address(tokenA), address(tokenB));
    }

    // ------------------------------------------------------------------ roles

    /// Owner (the timelock in production) holds upgrades and factories; the
    /// emergency admin (the Safe) restarts the system and names the guardian.
    function testRolesAreSplitByUrgency() public {
        address safe = makeAddr("safe");
        address guardian = makeAddr("guardian");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setEmergencyAdmin(safe);
        vm.prank(owner);
        registry.setEmergencyAdmin(safe);
        assertEq(registry.emergencyAdmin(), safe);

        // The Safe cannot touch what changes code.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, safe));
        registry.setFactories(address(factory), address(0));
        // Deployed before arming expectRevert, which the CREATE would consume.
        address newImpl = address(new DexRegistry());
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, safe));
        registry.upgradeToAndCall(newImpl, "");

        // It can do what must not wait.
        vm.prank(safe);
        registry.setGuardian(guardian);
        vm.prank(guardian);
        registry.pause();
        vm.prank(guardian);
        vm.expectRevert(DexRegistry.NotEmergencyAdmin.selector);
        registry.unpause();
        vm.prank(safe);
        registry.unpause();

        // Strangers can do neither; the owner can do both, so a lost Safe is
        // a delay rather than a permanent loss of control.
        vm.prank(stranger);
        vm.expectRevert(DexRegistry.NotEmergencyAdmin.selector);
        registry.setGuardian(stranger);
        vm.prank(owner);
        registry.setGuardian(address(0));
        assertEq(registry.guardian(), address(0));
    }

    function testPauseWindowRecordsBothEnds() public {
        vm.warp(10_000);
        vm.prank(owner);
        registry.pause();
        vm.warp(10_500);
        vm.prank(owner);
        registry.unpause();
        (bool isPaused, uint64 pausedAt, uint64 unpausedAt) = registry.pauseWindow();
        assertFalse(isPaused);
        assertEq(pausedAt, 10_000);
        assertEq(unpausedAt, 10_500);
    }

    function testFactoryOnlyPair() public {
        vm.expectRevert(SpotPoolFactory.NotPair.selector);
        factory.deploy(address(treasury), address(tokenA), address(tokenB), 3000);
    }

    function testTreasuryWithdrawOnlyOwner() public {
        tokenA.mint(address(treasury), 5 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.withdraw(address(tokenA), stranger, 5 ether);
        vm.prank(owner);
        treasury.withdraw(address(tokenA), owner, 5 ether);
        assertEq(tokenA.balanceOf(owner), 5 ether);
    }
}
