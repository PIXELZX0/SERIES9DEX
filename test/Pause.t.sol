// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DexRegistry} from "../src/DexRegistry.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {LpStatus} from "../src/interfaces/IPerpPool.sol";
import {Pausing} from "../src/libraries/Pausing.sol";
import {PerpFixture} from "./PerpPool.t.sol";

/// The emergency stop gates entry only. The tests that matter here are the
/// ones proving a pause cannot trap anybody's funds.
contract PauseTest is PerpFixture {
    address internal stranger = makeAddr("stranger");
    uint64 internal expiry;

    function setUp() public override {
        super.setUp();
        expiry = uint64(block.timestamp + 30 days);
        address[2] memory us = [lp, trader];
        for (uint256 i; i < us.length; i++) {
            vm.startPrank(us[i]);
            base.approve(address(pair), type(uint256).max);
            quote.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------- authority

    function testGuardianMayPauseButNotUnpause() public {
        vm.prank(guardian);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(guardian);
        vm.expectRevert(DexRegistry.NotEmergencyAdmin.selector);
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
        assertTrue(_open(trader, true, 1_000 ether, 500 ether));
        vm.prank(trader);
        pair.placeOrder(IPair.Side.SELL, 4.5e36, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        vm.startPrank(trader);
        vm.expectRevert(Pausing.Paused.selector);
        spot.swapExactIn(address(base), 1 ether, 0, trader);
        vm.expectRevert(Pausing.Paused.selector);
        spot.addLiquidity(1 ether, 4 ether, 0, 0, trader);
        vm.expectRevert(Pausing.Paused.selector);
        perp.requestDeposit(1_000 ether, 0, trader, trader, 0);
        vm.expectRevert(Pausing.Paused.selector);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 0, 0);
        vm.expectRevert(Pausing.Paused.selector);
        pair.placeOrder(IPair.Side.SELL, 4.6e36, 10 ether, expiry, 0);
        vm.expectRevert(Pausing.Paused.selector);
        pair.matchOrders(5);
        vm.expectRevert(Pausing.Paused.selector);
        pair.createSpotPool(FEE_PPM + 1);
        vm.stopPrank();
    }

    /// The mark is the likeliest thing to be wrong when the system is paused,
    /// and a liquidation against a wrong mark cannot be undone.
    function testPauseBlocksLiquidation() public {
        assertTrue(_open(trader, true, 1_030 ether, 2_500 ether));

        vm.prank(guardian);
        registry.pause();

        vm.prank(stranger);
        vm.expectRevert(Pausing.Paused.selector);
        perp.liquidate(trader, true);
    }

    // ------------------------------------------------------------ exits open

    /// The property that makes a pause safe: everybody can still get out.
    function testPauseNeverTrapsFunds() public {
        assertTrue(_open(trader, true, 2_000 ether, 1_000 ether));
        vm.prank(trader);
        uint256 orderId = pair.placeOrder(IPair.Side.SELL, 9e36, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        // Maker gets their escrow back.
        uint256 baseBefore = base.balanceOf(trader);
        vm.prank(trader);
        pair.cancelOrder(orderId);
        assertEq(base.balanceOf(trader) - baseBefore, 10 ether);

        // Trader closes the position and takes the payout.
        uint256 quoteBefore = quote.balanceOf(trader);
        assertTrue(_decrease(trader, true, 1_000 ether));
        assertGt(quote.balanceOf(trader), quoteBefore);
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);

        // LPs withdraw from both pools.
        uint256 spotShares = spot.sharesOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = spot.removeLiquidity(spotShares, 0, 0, lp);
        assertGt(a0, 0);
        assertGt(a1, 0);

        (LpStatus status, uint256 out) = _withdraw(perp, lp, perp.sharesOf(lp));
        assertEq(uint8(status), uint8(LpStatus.EXECUTED));
        assertGt(out, 0);

        // Housekeeping that moves nobody's money stays available too.
        spot.collectProtocolFees();
        perp.collectProtocolFees();
        spot.skim(lp);
        perp.updateFunding();
    }

    function testMarginMovesAndExpiredOrdersStayOpen() public {
        assertTrue(_open(trader, true, 5_000 ether, 1_000 ether));
        vm.prank(trader);
        uint256 orderId = pair.placeOrder(IPair.Side.SELL, 9e36, 10 ether, expiry, 0);

        vm.prank(guardian);
        registry.pause();

        vm.prank(trader);
        perp.addMargin(true, 50 ether);
        assertTrue(_removeMargin(trader, true, 100 ether));

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
        pair.placeOrder(IPair.Side.SELL, 4.5e36, 10 ether, expiry, 0);
        assertTrue(_open(trader, true, 1_000 ether, 100 ether));
    }
}
