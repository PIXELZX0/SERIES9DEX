// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PerpPool} from "../src/PerpPool.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {Pair} from "../src/Pair.sol";
import {Pausing} from "../src/libraries/Pausing.sol";
import {LpStatus} from "../src/interfaces/IPerpPool.sol";
import {PerpFixture} from "./PerpPool.t.sol";
import {MockBlocklistERC20} from "./mocks/MockERC20.sol";

/// Regression tests for the perp findings of the audit. Each one replays the
/// original proof of concept against the two-step design and checks that it
/// no longer pays.
contract PerpAuditTest is PerpFixture {
    // ----------------------------------------------------------------- C-1

    /// The next mark used to be computable a second before it was published,
    /// and positions opened and closed exactly at the mark: open at the old
    /// one, close at the new one, +2,101 on 5k margin in one second. A
    /// request is now priced by a window that starts after it, so seeing the
    /// move first buys nothing.
    function test_aKnownMoveCannotBeTradedAgainstTheVault() public {
        _rollMark();
        assertEq(perp.markX36(), 4e36);
        _swap(true, 10_000 ether); // organic move, +5%
        uint256 spotAfter = spot.spotPriceX36();

        uint256 q0 = quote.balanceOf(attacker);
        assertTrue(_open(attacker, true, 6_000 ether, 12_000 ether));
        (,, uint256 entryNotional) = _pos(attacker, true);
        assertEq(entryNotional, 12_000 ether * spotAfter / 1e36, "entered at the new price, not the stale mark");

        assertTrue(_decrease(attacker, true, 12_000 ether));
        assertLt(quote.balanceOf(attacker), q0, "round trip only pays fees");
        _accountingHolds(perp);
    }

    /// The exit side of the same lag: a long that sees the pool crash closes
    /// at a window made of post-crash prices, not at the stale mark.
    function test_aKnownCrashCannotBeEscaped() public {
        assertTrue(_open(trader, true, 5_000 ether, 5_000 ether)); // 20k notional at 4.0
        _swap(false, 12_000 ether); // pool ~ -21%
        uint256 spotAfter = spot.spotPriceX36();
        assertGt(perp.markX36(), spotAfter, "mark still stale right after the crash");

        uint256 before = quote.balanceOf(trader);
        assertTrue(_decrease(trader, true, 5_000 ether));
        uint256 payout = quote.balanceOf(trader) - before;
        uint256 lossAtSpot = 20_000 ether - 5_000 ether * spotAfter / 1e36;
        assertLt(payout, 5_000 ether - lossAtSpot + 1 ether, "paid at the post-crash price");
        _accountingHolds(perp);
    }

    // ----------------------------------------------------------------- M-4

    /// After an idle hour the deposit's own poke used to zero the mark, and
    /// the deposit was priced ignoring traders' open losses. Marks no longer
    /// lapse, and a deposit buys in at full mark-to-market while a withdrawal
    /// pays out without counting those losses — so the round trip loses.
    function test_depositAfterIdleCannotTakeTraderLosses() public {
        assertTrue(_open(trader, true, 2_000 ether, 2_500 ether)); // 10k notional, 5x
        _swap(false, 5_400 ether); // spot -10%
        _rollMark();
        vm.warp(block.timestamp + 1 hours); // idle hour
        assertGt(perp.markX36(), 0, "mark does not lapse");

        uint256 shares = _deposit(perp, attacker, 100_000 ether);
        (LpStatus status, uint256 out) = _withdraw(perp, attacker, shares);
        assertEq(uint8(status), uint8(LpStatus.EXECUTED));
        assertLt(out, 100_000 ether, "no share of the existing LPs' gains");
        _accountingHolds(perp);
    }

    /// An LP exiting while a position sits in bad debt used to be paid as if
    /// the whole loss would be collected. Unrealized losses now count for
    /// nothing on the way out.
    function test_withdrawalNeverPaysForUncollectibleLosses() public {
        uint256 aShares = _deposit(perp, attacker, 100_000 ether);
        assertTrue(_open(trader, true, 1_000 ether, 2_400 ether));
        _swap(false, 12_000 ether); // spot ~ -21%: equity < 0
        _rollMark();
        assertLt(perp.equityOf(trader, true), 0, "bad debt");

        vm.prank(owner);
        registry.pause();
        (, uint256 margin,) = _pos(trader, true);
        uint256 collectible = perp.totalLiquidity() + margin;
        uint256 fair = aShares * collectible / perp.totalShares();
        (LpStatus status, uint256 out) = _withdraw(perp, attacker, aShares);
        assertEq(uint8(status), uint8(LpStatus.EXECUTED), "exits stay open while paused");
        assertLe(out, fair, "no inflated exit");
    }

    /// Accrued but unsettled funding is the vault's: a deposit pays for it.
    function test_depositPaysForAccruedFunding() public {
        PerpPool hot = _newPerp(500, _params(10_000)); // 1%/h at full imbalance
        _deposit(hot, lp, 100_000 ether);
        assertTrue(_open(hot, trader, true, 2_000 ether, 2_500 ether));
        vm.warp(block.timestamp + 2 hours);
        hot.updateFunding();
        uint256 owed = 2_500 ether * hot.cumFundingLongX36() / 1e36;
        assertGt(owed, 190 ether);
        assertEq(hot.lpEquityForDeposit() - hot.lpEquityForWithdraw(), owed, "funding is in the deposit price");
    }

    // ----------------------------------------------------------------- M-5

    /// Two idle hours used to be erased: the poke zeroed the mark before
    /// funding read it, and the clock moved on regardless.
    function test_fundingSurvivesIdleSpans() public {
        PerpPool hot = _newPerp(500, _params(10_000));
        _deposit(hot, lp, 100_000 ether);
        assertTrue(_open(hot, trader, true, 2_000 ether, 2_500 ether)); // only side => 100% imbalance
        vm.warp(block.timestamp + 2 hours);
        vm.prank(trader); // the payer does it
        hot.updateFunding();
        uint256 owed = 2_500 ether * hot.cumFundingLongX36() / 1e36;
        assertApproxEqRel(owed, 200 ether, 1e16, "two hours at 1%/h on 10k");
    }

    // ----------------------------------------------------------------- M-6

    /// A liquidatable position used to be growable: leverage was checked on
    /// margin alone and maintenance not at all.
    function test_liquidatablePositionCannotGrow() public {
        assertTrue(_open(trader, true, 1_000 ether, 2_400 ether)); // ~9.9x
        _swap(false, 3_100 ether); // spot ~ -6%
        _rollMark();
        (uint256 sizeBefore,,) = _pos(trader, true);

        vm.prank(trader);
        vm.expectRevert(PerpPool.LeverageTooHigh.selector);
        perp.requestIncrease(true, 70 ether, 300 ether, 0, 0);
        (uint256 sizeAfter,,) = _pos(trader, true);
        assertEq(sizeAfter, sizeBefore);

        vm.prank(keeper);
        perp.liquidate(trader, true);
    }

    // ----------------------------------------------------------------- L-1

    /// A hedged long and short — no market risk, no funding — used to fill
    /// both per-side caps and lock every LP in. Withdrawals now answer to the
    /// net exposure, with gross held to twice the cap.
    function test_hedgedPairCannotLockLps() public {
        vm.prank(attacker);
        perp.requestIncrease(true, 8_000 ether, 19_000 ether, 0, 0);
        vm.prank(keeper);
        perp.requestIncrease(false, 8_000 ether, 19_000 ether, 0, 0);
        assertTrue(_execute(perp, attacker, true));
        assertTrue(_execute(perp, keeper, false));

        (LpStatus status,) = _withdraw(perp, lp, perp.sharesOf(lp) / 2);
        assertEq(uint8(status), uint8(LpStatus.EXECUTED), "half the vault can leave");
        (status,) = _withdraw(perp, lp, perp.sharesOf(lp) * 9 / 10);
        assertEq(uint8(status), uint8(LpStatus.REFUNDED), "gross exposure still bounds it");
        _accountingHolds(perp);
    }

    // ------------------------------------------------------------ M-9 depth

    function _thinMarket() internal returns (SpotPool thin, PerpPool p) {
        thin = SpotPool(pair.createSpotPool(500));
        p = PerpPool(pair.createPerpPool(address(quote), address(thin), FEE_PPM, _params(100)));
        address[2] memory who = [lp, attacker];
        for (uint256 i; i < who.length; i++) {
            vm.startPrank(who[i]);
            base.approve(address(thin), type(uint256).max);
            quote.approve(address(thin), type(uint256).max);
            quote.approve(address(p), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lp);
        thin.addLiquidity(1_000 ether, 4_000 ether, 0, 0, lp); // ~4k quote deep
        vm.prank(trader);
        quote.approve(address(p), type(uint256).max);
        vm.warp(block.timestamp + p.DEPTH_WINDOW());
        _deposit(p, lp, 100_000 ether);
    }

    /// A perp may price off any spot pool of its pair, including a thin one.
    /// Open interest per side is capped at half that pool's quote depth.
    function test_thinOracleCapsOpenInterest() public {
        (, PerpPool p) = _thinMarket();
        vm.prank(trader);
        vm.expectRevert(PerpPool.OracleTooShallow.selector);
        p.requestIncrease(true, 2_000 ether, 2_000 ether, 0, 0); // 8k notional on a 4k-deep oracle
        assertTrue(_open(p, trader, true, 1_000 ether, 400 ether), "1.6k fits");
    }

    /// Depth lent to the oracle pool for one window used to admit a position
    /// twenty times the pool's real depth (+47.7k after pushing the thin pool
    /// at the close). Depth now also counts its hour-long average.
    function test_rentedDepthDoesNotCount() public {
        (SpotPool thin, PerpPool p) = _thinMarket();
        vm.prank(attacker);
        thin.addLiquidity(99_000 ether, 396_000 ether, 0, 0, attacker); // 100x the depth
        vm.warp(block.timestamp + 6 minutes); // a full window of it
        vm.prank(attacker);
        vm.expectRevert(PerpPool.OracleTooShallow.selector);
        p.requestIncrease(true, 8_300 ether, 15_000 ether, 0, 0); // 60k notional
    }

    /// Depth held in the pool for the full hour admission averages over
    /// still counts, so it can be lent for an hour, and pulled the moment
    /// the position is admitted. The thin pool left behind is then cheap to
    /// push for one window — the entry's, the exit's. A settlement whose
    /// open interest is over the depth cap of its own window now also takes
    /// the oracle's average over the hour before the window, and the worse
    /// of the two fills: neither push pays.
    function test_depthLentForAnHourCannotSetTheFills() public {
        (SpotPool thin, PerpPool p) = _thinMarket();
        vm.startPrank(attacker);
        base.approve(address(thin), type(uint256).max);
        thin.addLiquidity(99_000 ether, 396_000 ether, 0, 0, attacker); // 100x the depth
        vm.warp(block.timestamp + 1 hours + 6 minutes);
        p.requestIncrease(true, 8_300 ether, 15_000 ether, 0, 0); // 60k: admitted
        thin.removeLiquidity(thin.sharesOf(attacker), 0, 0, attacker);

        // Push the thin pool down a third for the entry window.
        vm.warp(_settleAt(p, attacker, true) - p.MARK_WINDOW());
        thin.swapExactIn(address(base), 225 ether, 0, attacker);
        vm.stopPrank();
        assertTrue(_execute(p, attacker, true));
        (,, uint256 entryNotional,) = p.positions(attacker, true);
        assertEq(entryNotional, 60_000 ether, "entered at the hour's price, not the push");

        // Then push it up half for the exit window.
        vm.prank(attacker);
        p.requestDecrease(true, 15_000 ether, 0, 0);
        vm.warp(_settleAt(p, attacker, true) - p.MARK_WINDOW());
        vm.prank(attacker);
        thin.swapExactIn(address(quote), 1_700 ether, 0, attacker);
        assertGt(thin.spotPriceX36(), 5.9e36);
        uint256 before = quote.balanceOf(attacker);
        assertTrue(_execute(p, attacker, true));
        assertLt(quote.balanceOf(attacker) - before, 8_300 ether, "the push pays nothing");
    }

    /// Keeping the lent liquidity in for the first part of the exit window,
    /// and pulling it only to push the rest, used to hold an arithmetic mean
    /// of the pool's depth above the trigger: 44.9k paid out on 8.3k of
    /// margin. Depth is now a harmonic mean, which the thin stretch rules.
    function test_depthPulledMidWindowStillReadsThin() public {
        (SpotPool thin, PerpPool p) = _thinMarket();
        vm.startPrank(attacker);
        thin.addLiquidity(99_000 ether, 396_000 ether, 0, 0, attacker); // 100x the depth
        vm.warp(block.timestamp + 1 hours + 6 minutes);
        p.requestIncrease(true, 8_300 ether, 15_000 ether, 0, 0);
        vm.stopPrank();
        assertTrue(_execute(p, attacker, true)); // an honest entry: the liquidity is still in

        vm.prank(attacker);
        p.requestDecrease(true, 15_000 ether, 0, 0);
        vm.warp(_settleAt(p, attacker, true) - p.MARK_WINDOW() + 120); // deep for 120s of the window
        vm.startPrank(attacker);
        thin.removeLiquidity(thin.sharesOf(attacker), 0, 0, attacker);
        thin.swapExactIn(address(quote), 1_700 ether, 0, attacker); // thin and pushed for 180s
        vm.stopPrank();
        uint256 before = quote.balanceOf(attacker);
        assertTrue(_execute(p, attacker, true));
        assertLt(quote.balanceOf(attacker) - before, 8_300 ether, "the push pays nothing");
    }

    /// The thin-oracle trigger used to sit at the admission cap itself, and a
    /// side's ratio to depth grows with the square root of the price, so an
    /// honest long admitted near the cap tripped it on an ordinary +3% move
    /// and exited at the hour's price. It now trips at twice the cap.
    function test_honestPositionNearTheCapExitsAtTheMark() public {
        _deposit(perp, lp, 900_000 ether); // depth, not utilization, binds
        assertTrue(_open(trader, true, 25_000 ether, 49_700 ether)); // 198.8k of a 200k depth cap
        _swap(true, 6_000 ether); // +3%
        vm.prank(trader);
        perp.requestDecrease(true, 49_700 ether, 0, 0);
        uint256 before = quote.balanceOf(trader);
        assertTrue(_execute(perp, trader, true));
        // ~29.8k at the mark; the hour's price would pay ~23.9k.
        assertGt(quote.balanceOf(trader) - before, 29_000 ether);
    }

    // ------------------------------------------------------- H-1 (review)

    /// A request that missed its epoch used to be re-checked at the opposite
    /// extreme of the prices it rolled through; at max leverage any move
    /// failed that check and refunded the margin — a free walk-away from a
    /// fill gone bad. It is now judged at its fill, which only got worse.
    function test_rolledIncreaseCannotBeWalkedAwayFrom() public {
        _rollMark();
        vm.prank(attacker);
        perp.requestIncrease(true, 1_031 ether, 2_500 ether, 0, 0); // 10x at 4.0
        uint64 settleAt = _settleAt(perp, attacker, true);
        vm.warp(settleAt + perp.epoch()); // skipped on purpose
        _swap(false, 1_000 ether); // spot ~ -2% after the window
        assertFalse(perp.executeOrder(attacker, true, _hints()), "rolls");

        assertTrue(_execute(perp, attacker, true), "fills at the first mark, no refund");
        (uint256 size,, uint256 entryNotional) = _pos(attacker, true);
        assertEq(size, 2_500 ether);
        assertEq(entryNotional, 10_000 ether);
        _accountingHolds(perp);
    }

    // ------------------------------------------------------------ M-9 pause

    /// While paused the spot pool cannot be arbitraged, so the mark freezes
    /// at the boundary before the pause instead of rolling over whatever the
    /// price was when the stop landed. Exits settle at it; margin can be
    /// added; liquidations wait until a full window after the restart.
    function test_pauseFreezesTheMarkAndKeepsExitsOpen() public {
        assertTrue(_open(trader, true, 5_000 ether, 5_000 ether));
        _rollMark();
        uint256 markBefore = perp.markX36();
        vm.warp(block.timestamp + 30);
        _swap(false, 5_000 ether); // a drop lands right before the stop
        vm.prank(guardian);
        registry.pause();

        vm.warp(block.timestamp + 1 hours);
        assertEq(perp.markX36(), markBefore, "frozen at the last boundary before the pause");

        vm.prank(trader);
        perp.addMargin(true, 100 ether); // open while paused
        vm.prank(keeper);
        vm.expectRevert(Pausing.Paused.selector);
        perp.liquidate(trader, true);

        uint256 before = quote.balanceOf(trader);
        assertTrue(_decrease(trader, true, 2_500 ether), "exit executes while paused");
        assertGt(quote.balanceOf(trader), before);

        vm.prank(owner);
        registry.unpause();
        vm.prank(keeper);
        vm.expectRevert(PerpPool.LiquidationCooldown.selector);
        perp.liquidate(trader, true);
        _accountingHolds(perp);
    }

    // ------------------------------------------------------- H-2 (review)

    /// An exit requested while paused used to settle at the frozen mark,
    /// public when it was requested: a long that saw a -21% crash land just
    /// before the stop took 4,878 out instead of 840. The pool's price during
    /// the pause now counts too, and the worse of the two fills.
    function test_exitDuringAPauseTakesThePoolPriceToo() public {
        assertTrue(_open(trader, true, 5_000 ether, 5_000 ether)); // 20k notional at 4.0
        _rollMark();
        _swap(false, 12_000 ether); // ~ -21%
        uint256 crashed = spot.spotPriceX36();
        vm.warp(block.timestamp + 20);
        vm.prank(guardian);
        registry.pause();
        assertGt(perp.markX36(), crashed, "frozen mark predates the crash");

        uint256 before = quote.balanceOf(trader);
        assertTrue(_decrease(trader, true, 5_000 ether));
        uint256 payout = quote.balanceOf(trader) - before;
        uint256 lossAtPoolPrice = 20_000 ether - 5_000 ether * crashed / 1e36;
        assertLe(payout, 5_000 ether - lossAtPoolPrice, "paid at the in-pause pool price");
        _accountingHolds(perp);
    }

    /// An increase whose settlement fell inside a pause is refunded whenever
    /// it is executed — during the pause or after it.
    function test_increaseSettlingInsideAPauseIsRefunded() public {
        uint256 before = quote.balanceOf(trader);
        vm.prank(trader);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 0, 0);
        uint64 settleAt = _settleAt(perp, trader, true);
        vm.prank(guardian);
        registry.pause();
        vm.warp(settleAt + 10 minutes);
        vm.prank(owner);
        registry.unpause();

        assertFalse(perp.executeOrder(trader, true, _hints()));
        assertEq(quote.balanceOf(trader), before);
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
    }

    // ---------------------------------------------------- second review

    /// A request whose limit the spot had already run past when it was
    /// admitted fails at execution by design, and used to hold the side's
    /// capacity — blocking traders and LP exits — for nothing. It now pays
    /// its pool's open fee on the notional it held.
    function test_capacityHeldByAFailingIncreaseIsPaidFor() public {
        _rollMark();
        _swap(true, 20_000 ether); // the spot runs ahead of the mark
        uint256 mark = perp.markX36();
        uint256 before = quote.balanceOf(attacker);
        vm.prank(attacker);
        perp.requestIncrease(true, 8_000 ether, 19_000 ether, mark, 0); // 76k of an 80k cap

        vm.prank(trader);
        vm.expectRevert(PerpPool.UtilizationExceeded.selector);
        perp.requestIncrease(true, 1_000 ether, 2_000 ether, 0, 0);

        assertFalse(_execute(perp, attacker, true), "settles above the limit");
        assertEq(before - quote.balanceOf(attacker), 228 ether, "0.3% of the 76k it held");
        assertEq(perp.pendingLongNotional(), 0);
        _accountingHolds(perp);
    }

    /// The fee comes out of the request's own escrow, so a request riding on
    /// an existing position's spare margin, escrowing nothing, failed for
    /// free. The escrow now has to cover it.
    function test_requestMustEscrowItsFailureFee() public {
        assertTrue(_open(attacker, true, 9_000 ether, 1 ether)); // a tiny long with parked margin
        vm.prank(attacker);
        vm.expectRevert(PerpPool.MarginBelowFee.selector);
        perp.requestIncrease(true, 0, 19_000 ether, 0, 0);
        vm.prank(attacker);
        perp.requestIncrease(true, 228 ether, 19_000 ether, 0, 0);
    }

    /// LPs used to be able to leave between an increase's admission and its
    /// fill, handing the ones who stayed several times the exposure the cap
    /// allows. A pending increase counts against exits like the position it
    /// becomes.
    function test_lpsCannotOutrunAnAdmittedIncrease() public {
        vm.prank(trader);
        perp.requestIncrease(true, 8_500 ether, 19_900 ether, 0, 0); // 79.6k of an 80k cap
        (LpStatus status,) = _withdraw(perp, lp, perp.sharesOf(lp) * 9 / 10);
        assertEq(uint8(status), uint8(LpStatus.REFUNDED), "the vault is committed to the increase");
        assertTrue(perp.executeOrder(trader, true, _hints()));
        assertLe(perp.longOpenNotional(), perp.totalLiquidity() * 8 / 10, "inside the cap");
        _accountingHolds(perp);
    }

    /// A deposit settling in a pause that began within a window of its
    /// oracle pool's seeding used to revert forever: the frozen mark's window
    /// reached back before the pool had a price. Such a deposit is now
    /// refunded without reading one, however late it is executed.
    function test_depositSettlingInAPauseOnAFreshOracleIsRefunded() public {
        SpotPool fresh = SpotPool(pair.createSpotPool(500));
        PerpPool p = PerpPool(pair.createPerpPool(address(quote), address(fresh), FEE_PPM, _params(100)));
        vm.startPrank(lp);
        base.approve(address(fresh), type(uint256).max);
        quote.approve(address(fresh), type(uint256).max);
        quote.approve(address(p), type(uint256).max);
        fresh.addLiquidity(1_000 ether, 4_000 ether, 0, 0, lp);
        uint256 before = quote.balanceOf(lp);
        uint256 id = p.requestDeposit(1_000 ether, 0, lp, lp, 0);
        vm.stopPrank();
        vm.prank(guardian);
        registry.pause();
        vm.warp(_lpSettleAt(p, id) + 1 hours);
        vm.prank(owner);
        registry.unpause();

        p.executeLp(id, _hints());
        (LpStatus status,,,) = p.lpRequestOutcome(id);
        assertEq(uint8(status), uint8(LpStatus.REFUNDED));
        assertEq(quote.balanceOf(lp), before);
    }

    /// A swap in the second trading restarted used to stand in for the
    /// pool's price during the pause: an observation read in its boundary's
    /// own second returned the reserves after that second's trades. It now
    /// returns those in effect up to the boundary, before and after.
    function test_restartSecondSwapDoesNotSetThePausePrice() public {
        assertTrue(_open(trader, true, 5_000 ether, 5_000 ether));
        _rollMark();
        vm.prank(guardian);
        registry.pause();
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(trader);
        perp.requestDecrease(true, 5_000 ether, 0, 0);
        vm.warp(_settleAt(perp, trader, true));
        (,,, uint256 r0, uint256 r1) = spot.observe(block.timestamp / 60, 0);

        vm.prank(owner);
        registry.unpause();
        _swap(false, 12_000 ether); // a crash in the restart second
        (,,, uint256 r0After, uint256 r1After) = spot.observe(block.timestamp / 60, 0);
        assertEq(r0After, r0);
        assertEq(r1After, r1);

        uint256 before = quote.balanceOf(trader);
        assertTrue(perp.executeOrder(trader, true, _hints()));
        assertGt(quote.balanceOf(trader) - before, 4_800 ether, "settled at the pause price");
    }

    /// A refund the token refused — a blocklisted trader's — used to revert
    /// every execution that could resolve the request, so it only rolled and
    /// its reservation was held for good. The refund is now credited for
    /// `claim` and the request resolves.
    function test_refusedRefundCannotPinAReservation() public {
        MockBlocklistERC20 q2 = new MockBlocklistERC20(18);
        Pair p2 = Pair(registry.createPair(address(base), address(q2)));
        SpotPool s2 = SpotPool(p2.createSpotPool(3000));
        PerpPool pp = PerpPool(p2.createPerpPool(address(q2), address(s2), FEE_PPM, _params(100)));
        address[3] memory who = [lp, trader, keeper];
        for (uint256 i; i < who.length; i++) {
            q2.mint(who[i], 10_000_000 ether);
            vm.startPrank(who[i]);
            base.approve(address(s2), type(uint256).max);
            q2.approve(address(s2), type(uint256).max);
            q2.approve(address(pp), type(uint256).max);
            vm.stopPrank();
        }
        vm.startPrank(lp);
        if (s2.token0() == address(base)) s2.addLiquidity(100_000 ether, 400_000 ether, 0, 0, lp);
        else s2.addLiquidity(400_000 ether, 100_000 ether, 0, 0, lp);
        vm.warp(block.timestamp + pp.DEPTH_WINDOW());
        uint256 id = pp.requestDeposit(100_000 ether, 0, lp, lp, 0);
        vm.stopPrank();
        vm.warp(_lpSettleAt(pp, id));
        pp.executeLp(id, _hints());

        uint256 mark = pp.markX36();
        vm.prank(trader);
        pp.requestIncrease(true, 8_500 ether, 19_900 ether, mark, 0); // 79.6k of an 80k cap
        vm.prank(keeper);
        s2.swapExactIn(address(q2), 20_000 ether, 0, keeper); // the long will miss its limit
        q2.setBlocked(trader, true);

        (, uint64 settleAt,,,,,,,) = pp.orders(trader, true);
        vm.warp(settleAt);
        assertFalse(pp.executeOrder(trader, true, _hints()));
        assertEq(pp.pendingLongNotional(), 0, "reservation released");
        uint256 refund = 8_500 ether - uint256(79_600 ether) * FEE_PPM / 1e6;
        assertEq(pp.claimableQuote(trader), refund);

        vm.prank(trader);
        pp.claim(keeper);
        assertEq(pp.claimableQuote(trader), 0);
        assertEq(
            q2.balanceOf(address(pp)), pp.totalLiquidity() + pp.protocolFeesQuote() + pp.escrowedQuote(), "accounting"
        );
    }
}
