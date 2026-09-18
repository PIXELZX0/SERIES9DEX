// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PerpPool} from "../src/PerpPool.sol";
import {PerpPoolFactory} from "../src/PerpPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {Pausing} from "../src/libraries/Pausing.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// The emergency stop gates entry only. The tests that matter here are the
/// ones proving a pause cannot trap anybody's funds.
contract PauseTest is Test {
    DexRegistry internal registry;
    Pair internal pair;
    SpotPool internal spot;
    PerpPool internal perp;
    MockERC20 internal base;
    MockERC20 internal quote;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    uint64 internal expiry;

    uint32 internal constant FEE_PPM = 3000;

    function setUp() public {
        ProtocolTreasury t = ProtocolTreasury(
            address(
                new ERC1967Proxy(address(new ProtocolTreasury()), abi.encodeCall(ProtocolTreasury.initialize, (owner)))
            )
        );
        registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(new DexRegistry()), abi.encodeCall(DexRegistry.initialize, (owner, address(t)))
                )
            )
        );
        SpotPoolFactory sf = new SpotPoolFactory(address(registry));
        PerpPoolFactory pf = new PerpPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setFactories(address(sf), address(pf));
        registry.setGuardian(guardian);
        vm.stopPrank();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (base, quote) = address(a) < address(b) ? (a, b) : (b, a);
        pair = Pair(registry.createPair(address(base), address(quote)));
        spot = SpotPool(pair.createSpotPool(FEE_PPM));
        perp =
            PerpPool(pair.createPerpPool(address(quote), address(spot), FEE_PPM, PerpParams(10, 500, 100, 8000, 100)));
        expiry = uint64(block.timestamp + 30 days);

        address[2] memory us = [lp, trader];
        for (uint256 i; i < us.length; i++) {
            base.mint(us[i], 1_000_000 ether);
            quote.mint(us[i], 1_000_000 ether);
            vm.startPrank(us[i]);
            base.approve(address(spot), type(uint256).max);
            quote.approve(address(spot), type(uint256).max);
            quote.approve(address(perp), type(uint256).max);
            base.approve(address(pair), type(uint256).max);
            quote.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }

        vm.startPrank(lp);
        spot.addLiquidity(10_000 ether, 40_000 ether, 0, 0, lp);
        perp.addLiquidity(100_000 ether, 0, lp);
        vm.stopPrank();
    }

    function _warmMark() internal {
        perp.pokeMark();
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
    }

    // ------------------------------------------------------------- authority

    function testGuardianMayPauseButNotUnpause() public {
        vm.prank(guardian);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guardian));
        registry.unpause();

        vm.prank(owner);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function testOwnerMayPauseAndStrangerMayNot() public {
        vm.prank(stranger);
        vm.expectRevert(DexRegistry.NotPauser.selector);
        registry.pause();

        vm.prank(owner);
        registry.pause();
        assertTrue(registry.paused());
    }

    function testRedundantTransitionsRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(DexRegistry.AlreadyInState.selector);
        registry.unpause();
        registry.pause();
        vm.expectRevert(DexRegistry.AlreadyInState.selector);
        registry.pause();
        vm.stopPrank();
    }

    function testClearingGuardianRemovesTheFastPath() public {
        vm.prank(owner);
        registry.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(DexRegistry.NotPauser.selector);
        registry.pause();
    }

    // ----------------------------------------------------------- entry stops

    function testPauseBlocksEveryEntryPoint() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 1_000 ether, 500 ether);
        vm.prank(trader);
        pair.placeOrder(IPair.Side.SELL, 4.5e18, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        vm.startPrank(trader);
        vm.expectRevert(Pausing.Paused.selector);
        spot.swapExactIn(address(base), 1 ether, 0, trader);
        vm.expectRevert(Pausing.Paused.selector);
        spot.addLiquidity(1 ether, 4 ether, 0, 0, trader);
        vm.expectRevert(Pausing.Paused.selector);
        perp.addLiquidity(1_000 ether, 0, trader);
        vm.expectRevert(Pausing.Paused.selector);
        perp.openPosition(true, 1_000 ether, 100 ether);
        vm.expectRevert(Pausing.Paused.selector);
        perp.addMargin(true, 1 ether);
        vm.expectRevert(Pausing.Paused.selector);
        pair.placeOrder(IPair.Side.SELL, 4.6e18, 10 ether, expiry, 0);
        vm.expectRevert(Pausing.Paused.selector);
        pair.matchOrders(5);
        vm.expectRevert(Pausing.Paused.selector);
        pair.createSpotPool(FEE_PPM + 1);
        vm.stopPrank();
    }

    /// The mark is the likeliest thing to be wrong when the system is paused,
    /// and a liquidation against a wrong mark cannot be undone.
    function testPauseBlocksLiquidation() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 1_030 ether, 2_500 ether);

        vm.prank(guardian);
        registry.pause();

        vm.prank(stranger);
        vm.expectRevert(Pausing.Paused.selector);
        perp.liquidate(trader, true);
    }

    // ------------------------------------------------------------ exits open

    /// The property that makes a pause safe: everybody can still get out.
    function testPauseNeverTrapsFunds() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 2_000 ether, 1_000 ether);
        vm.prank(trader);
        uint256 orderId = pair.placeOrder(IPair.Side.SELL, 9e18, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        // Maker gets their escrow back.
        uint256 baseBefore = base.balanceOf(trader);
        vm.prank(trader);
        pair.cancelOrder(orderId);
        assertEq(base.balanceOf(trader) - baseBefore, 10 ether);

        // Trader closes the position and takes the payout.
        uint256 quoteBefore = quote.balanceOf(trader);
        vm.prank(trader);
        perp.decreasePosition(true, 1_000 ether);
        assertGt(quote.balanceOf(trader), quoteBefore);
        (uint256 size,,,) = perp.positions(trader, true);
        assertEq(size, 0);

        // LPs withdraw from both pools.
        uint256 spotShares = spot.sharesOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = spot.removeLiquidity(spotShares, 0, 0, lp);
        assertGt(a0, 0);
        assertGt(a1, 0);

        uint256 perpShares = perp.sharesOf(lp);
        vm.prank(lp);
        uint256 out = perp.removeLiquidity(perpShares, 0, lp);
        assertGt(out, 0);

        // Housekeeping that moves nobody's money stays available too.
        spot.collectProtocolFees();
        perp.collectProtocolFees();
        spot.skim(lp);
        perp.pokeMark();
        perp.updateFunding();
    }

    function testRemoveMarginAndExpiredOrdersStayOpen() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 5_000 ether, 1_000 ether);
        vm.prank(trader);
        uint256 orderId = pair.placeOrder(IPair.Side.SELL, 9e18, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        vm.prank(trader);
        perp.removeMargin(true, 100 ether);

        vm.warp(uint256(expiry) + 1);
        uint256 baseBefore = base.balanceOf(trader);
        vm.prank(stranger); // permissionless
        pair.removeExpired(orderId);
        assertEq(base.balanceOf(trader) - baseBefore, 10 ether);
    }

    function testUnpauseRestoresEverything() public {
        vm.prank(guardian);
        registry.pause();
        vm.prank(owner);
        registry.unpause();

        vm.prank(trader);
        spot.swapExactIn(address(base), 1 ether, 0, trader);
        vm.prank(trader);
        pair.placeOrder(IPair.Side.SELL, 4.5e18, 10 ether, expiry, 0);
    }
}
