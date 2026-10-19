// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PerpPool} from "../src/PerpPool.sol";
import {PerpPoolFactory} from "../src/PerpPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {PerpParams, LpStatus} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Shared fixture for the perp suites: a 4.0 spot pool deep enough to carry
/// the open interest the tests use, a perp pool on it, and helpers that walk
/// a request through its settlement window.
abstract contract PerpFixture is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    Pair internal pair;
    SpotPool internal spot;
    PerpPool internal perp;
    MockERC20 internal base; // token0
    MockERC20 internal quote; // token1

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    uint32 internal constant FEE_PPM = 3000;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        treasury = ProtocolTreasury(
            address(
                new ERC1967Proxy(address(new ProtocolTreasury()), abi.encodeCall(ProtocolTreasury.initialize, (owner)))
            )
        );
        registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(new DexRegistry()), abi.encodeCall(DexRegistry.initialize, (owner, address(treasury)))
                )
            )
        );
        vm.startPrank(owner);
        registry.setFactories(
            address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry)))
        );
        registry.setGuardian(guardian);
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (base, quote) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        pair = Pair(registry.createPair(address(base), address(quote)));
        spot = SpotPool(pair.createSpotPool(FEE_PPM));
        perp = _newPerp(FEE_PPM, _params(100));

        // Spot at 4.0 (quote per base), deep enough that the oracle-depth cap
        // sits well above every position below. Positions are admitted only
        // once the oracle has a full DEPTH_WINDOW of history.
        vm.prank(lp);
        spot.addLiquidity(100_000 ether, 400_000 ether, 0, 0, lp);
        vm.warp(block.timestamp + perp.DEPTH_WINDOW());
        _deposit(perp, lp, 100_000 ether);
    }

    function _params(uint64 fundingCoeff) internal pure returns (PerpParams memory) {
        return PerpParams({
            maxLeverageX: 10,
            maintenanceMarginBps: 500,
            liquidationFeeBps: 100,
            maxUtilizationBps: 8000,
            fundingCoeffPpmPerHour: fundingCoeff
        });
    }

    function _newPerp(uint32 fee, PerpParams memory params) internal returns (PerpPool p) {
        p = PerpPool(pair.createPerpPool(address(quote), address(spot), fee, params));
        address[5] memory users = [lp, trader, keeper, owner, attacker];
        for (uint256 i = 0; i < users.length; i++) {
            if (base.balanceOf(users[i]) == 0) {
                base.mint(users[i], 100_000_000 ether);
                quote.mint(users[i], 100_000_000 ether);
            }
            vm.startPrank(users[i]);
            base.approve(address(spot), type(uint256).max);
            quote.approve(address(spot), type(uint256).max);
            quote.approve(address(p), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _hints() internal pure returns (uint256[3] memory h) {}

    // ---------------------------------------------------------------- flows

    function _settleAt(PerpPool p, address who, bool isLong) internal view returns (uint64 settleAt) {
        (, settleAt,,,,,,,) = p.orders(who, isLong);
    }

    function _execute(PerpPool p, address who, bool isLong) internal returns (bool ok) {
        vm.warp(_settleAt(p, who, isLong));
        ok = p.executeOrder(who, isLong, _hints());
    }

    function _open(PerpPool p, address who, bool isLong, uint256 margin, uint256 size) internal returns (bool) {
        vm.prank(who);
        p.requestIncrease(isLong, margin, size, 0, 0);
        return _execute(p, who, isLong);
    }

    function _open(address who, bool isLong, uint256 margin, uint256 size) internal returns (bool) {
        return _open(perp, who, isLong, margin, size);
    }

    function _decrease(address who, bool isLong, uint256 size) internal returns (bool) {
        vm.prank(who);
        perp.requestDecrease(isLong, size, 0, 0);
        return _execute(perp, who, isLong);
    }

    function _removeMargin(address who, bool isLong, uint256 amount) internal returns (bool) {
        vm.prank(who);
        perp.requestRemoveMargin(isLong, amount, 0);
        return _execute(perp, who, isLong);
    }

    function _lpSettleAt(PerpPool p, uint256 id) internal view returns (uint64 settleAt) {
        (,,,,, settleAt,,,,,,) = p.lpRequests(id);
    }

    function _deposit(PerpPool p, address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        uint256 id = p.requestDeposit(amount, 0, who, who, 0);
        vm.warp(_lpSettleAt(p, id));
        p.executeLp(id, _hints());
        LpStatus status;
        (status,,, shares) = p.lpRequestOutcome(id);
        assertEq(uint8(status), uint8(LpStatus.EXECUTED), "deposit executed");
    }

    function _withdraw(PerpPool p, address who, uint256 shares) internal returns (LpStatus status, uint256 out) {
        vm.prank(who);
        uint256 id = p.requestWithdraw(shares, 0, who, who, 0);
        vm.warp(_lpSettleAt(p, id));
        p.executeLp(id, _hints());
        (status,,, out) = p.lpRequestOutcome(id);
    }

    function _swap(bool up, uint256 amountIn) internal {
        vm.prank(keeper);
        spot.swapExactIn(up ? address(quote) : address(base), amountIn, 0, keeper);
    }

    /// Warp until the current mark's whole window is after now.
    function _rollMark() internal {
        vm.warp((block.timestamp / 60 + 1) * 60 + perp.MARK_WINDOW());
    }

    function _pos(address who, bool isLong)
        internal
        view
        returns (uint256 size, uint256 margin, uint256 entryNotional)
    {
        (size, margin, entryNotional,) = perp.positions(who, isLong);
    }

    function _accountingHolds(PerpPool p) internal view {
        address[4] memory who = [trader, keeper, attacker, lp];
        uint256 margins;
        for (uint256 i; i < who.length; i++) {
            (, uint256 m1,,) = p.positions(who[i], true);
            (, uint256 m2,,) = p.positions(who[i], false);
            margins += m1 + m2;
        }
        assertEq(
            quote.balanceOf(address(p)),
            p.totalLiquidity() + margins + p.protocolFeesQuote() + p.escrowedQuote(),
            "accounting invariant"
        );
    }
}

contract PerpPoolTest is PerpFixture {
    // ------------------------------------------------------------- oracle

    function testMarkIsTheTwapOfTheWindow() public view {
        assertEq(perp.markX36(), 4e36);
    }

    function testMarkFollowsThePoolAfterAWindow() public {
        _swap(true, 50_000 ether);
        uint256 spotNow = spot.spotPriceX36();
        // Mid-window the mark is part way there; a full window later it is there.
        vm.warp((block.timestamp / 60 + 3) * 60);
        uint256 mid = perp.markX36();
        assertGt(mid, 4e36);
        assertLt(mid, spotNow);
        _rollMark();
        assertEq(perp.markX36(), spotNow);
    }

    /// An idle pool's price has not changed, so its mark is still good: the
    /// mark is a window ending now, not one sample stretching back to the
    /// last trade.
    function testIdlePoolKeepsAMark() public {
        vm.warp(block.timestamp + 3 days);
        assertEq(perp.markX36(), 4e36);
        assertTrue(_open(trader, true, 1_000 ether, 100 ether));
    }

    function testRequestNeedsASeededPool() public {
        SpotPool empty = SpotPool(pair.createSpotPool(FEE_PPM + 9));
        PerpPool p = PerpPool(pair.createPerpPool(address(quote), address(empty), FEE_PPM, _params(100)));
        vm.startPrank(trader);
        quote.approve(address(p), type(uint256).max);
        vm.expectRevert(PerpPool.MarkNotReady.selector);
        p.requestIncrease(true, 100 ether, 10 ether, 0, 0);
        // A deposit's window must have a price too, so it needs the pool seeded.
        vm.expectRevert(PerpPool.MarkNotReady.selector);
        p.requestDeposit(1_000 ether, 0, trader, trader, 0);
        vm.stopPrank();
    }

    /// A new market takes positions once its oracle has a full hour of
    /// history, so depth lent to the pool for one window cannot open them.
    function testNewMarketWaitsForDepthHistory() public {
        SpotPool fresh = SpotPool(pair.createSpotPool(FEE_PPM + 11));
        PerpPool p = PerpPool(pair.createPerpPool(address(quote), address(fresh), FEE_PPM, _params(100)));
        vm.startPrank(lp);
        base.approve(address(fresh), type(uint256).max);
        quote.approve(address(fresh), type(uint256).max);
        quote.approve(address(p), type(uint256).max);
        fresh.addLiquidity(100_000 ether, 400_000 ether, 0, 0, lp);
        vm.stopPrank();
        _deposit(p, lp, 100_000 ether);
        vm.prank(trader);
        quote.approve(address(p), type(uint256).max);

        vm.prank(trader);
        vm.expectRevert(PerpPool.MarkNotReady.selector);
        p.requestIncrease(true, 1_000 ether, 100 ether, 0, 0);
        vm.warp(block.timestamp + p.DEPTH_WINDOW());
        assertTrue(_open(p, trader, true, 1_000 ether, 100 ether));
    }

    // ------------------------------------------------------------ requests

    function testRequestSettlesAfterItsWindow() public {
        vm.prank(trader);
        perp.requestIncrease(true, 1_000 ether, 1_000 ether, 0, 0);
        uint64 settleAt = _settleAt(perp, trader, true);
        assertEq(settleAt, perp.nextSettleAt());
        assertGt(settleAt - block.timestamp, perp.MARK_WINDOW());

        vm.warp(settleAt - 1);
        uint256[3] memory h;
        vm.expectRevert(PerpPool.NotSettled.selector);
        perp.executeOrder(trader, true, h);

        vm.warp(settleAt);
        vm.prank(keeper); // anyone
        assertTrue(perp.executeOrder(trader, true, h));
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 1_000 ether);
        _accountingHolds(perp);
    }

    /// Pending interest is held from admission, so two requests cannot both
    /// fit into the same headroom.
    function testAdmissionReservesCapacity() public {
        // Cap: 80% of ~100k equity = 80k notional = 20k base at 4.0.
        vm.prank(trader);
        perp.requestIncrease(true, 10_000 ether, 15_000 ether, 0, 0);
        assertEq(perp.pendingLongNotional(), 60_000 ether);
        vm.prank(keeper);
        vm.expectRevert(PerpPool.UtilizationExceeded.selector);
        perp.requestIncrease(true, 10_000 ether, 6_000 ether, 0, 0);

        assertTrue(_execute(perp, trader, true));
        assertEq(perp.pendingLongNotional(), 0, "released on execution");
    }

    /// A pending request is judged on the position it was made against.
    function testAddMarginWaitsForAPendingRequest() public {
        assertTrue(_open(trader, true, 2_000 ether, 1_000 ether));
        vm.prank(trader);
        perp.requestDecrease(true, 500 ether, 0, 0);
        vm.prank(trader);
        vm.expectRevert(PerpPool.OrderPending.selector);
        perp.addMargin(true, 100 ether);
        assertTrue(_execute(perp, trader, true));
        vm.prank(trader);
        perp.addMargin(true, 100 ether);
    }

    function testOnePendingOrderPerSide() public {
        vm.startPrank(trader);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 0, 0);
        vm.expectRevert(PerpPool.OrderPending.selector);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 0, 0);
        perp.requestIncrease(false, 1_000 ether, 100 ether, 0, 0); // other side is free
        vm.stopPrank();
    }

    function testExecutionFeeGoesToTheExecutor() public {
        vm.prank(trader);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 0, 5 ether);
        vm.warp(_settleAt(perp, trader, true));
        uint256 before = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.executeOrder(trader, true, _hints());
        assertEq(quote.balanceOf(keeper) - before, 5 ether);
        _accountingHolds(perp);
    }

    /// A request that misses its settlement epoch rolls to a fresh window
    /// and fills at the worst mark it has been through, so waiting to see
    /// where the price goes never pays.
    function testMissedEpochRollsAndKeepsTheWorsePrice() public {
        vm.prank(trader);
        perp.requestIncrease(true, 5_000 ether, 1_000 ether, 0, 0);
        uint64 settleAt = _settleAt(perp, trader, true);
        vm.warp(settleAt + perp.epoch()); // epoch missed
        _swap(true, 50_000 ether); // price up in the meantime

        assertFalse(perp.executeOrder(trader, true, _hints()), "rolls, does not execute");
        (, uint64 rolledAt,,,,,, uint256 low, uint256 high) = perp.orders(trader, true);
        assertEq(low, 4e36);
        assertEq(high, 4e36);
        assertGt(rolledAt, settleAt);

        assertTrue(_execute(perp, trader, true));
        (,, uint256 entryNotional) = _pos(trader, true);
        assertGt(entryNotional, 4_000 ether, "long pays the higher of the two marks");
        _accountingHolds(perp);
    }

    /// The mirror case: a close that misses its epoch while the price rises
    /// still closes at the lower mark.
    function testMissedCloseKeepsTheLowerPrice() public {
        assertTrue(_open(trader, true, 5_000 ether, 1_000 ether));
        vm.prank(trader);
        perp.requestDecrease(true, 1_000 ether, 0, 0);
        uint64 settleAt = _settleAt(perp, trader, true);
        vm.warp(settleAt + perp.epoch());
        (uint256 firstMark,) = perp.twapAt(settleAt, perp.MARK_WINDOW(), 0, 0);
        _swap(true, 50_000 ether);
        assertFalse(perp.executeOrder(trader, true, _hints()));

        uint256 before = quote.balanceOf(trader);
        assertTrue(_execute(perp, trader, true));
        uint256 payout = quote.balanceOf(trader) - before;
        assertLe(payout, 5_000 ether + 1_000 ether * firstMark / 1e36 - 4_000 ether, "no gain from the rise");
    }

    function testAcceptablePriceBoundsTheFill() public {
        uint256 before = quote.balanceOf(trader);
        vm.prank(trader);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 4e36, 0); // limit at today's mark
        uint256 vaultBefore = perp.totalLiquidity() + perp.protocolFeesQuote();
        _swap(true, 20_000 ether); // the price runs up before the window opens
        assertFalse(_execute(perp, trader, true), "settled above the limit");
        // The margin comes back less the open fee on the 400 it held.
        uint256 fee = uint256(400 ether) * FEE_PPM / 1e6;
        assertEq(before - quote.balanceOf(trader), fee, "margin refunded less the fee");
        assertEq(perp.totalLiquidity() + perp.protocolFeesQuote() - vaultBefore, fee, "fee to LPs and protocol");
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        _accountingHolds(perp);
    }

    /// A request must be fillable at admission: a limit on the wrong side of
    /// the mark, or too little margin, would hold capacity for free until it
    /// failed and got its margin back.
    function testUnfillableRequestsAreRefusedAtAdmission() public {
        vm.startPrank(trader);
        vm.expectRevert(PerpPool.UnfillableLimit.selector);
        perp.requestIncrease(true, 1_000 ether, 100 ether, 3.9e36, 0);
        vm.expectRevert(PerpPool.UnfillableLimit.selector);
        perp.requestIncrease(false, 1_000 ether, 100 ether, 4.1e36, 0);
        vm.expectRevert(PerpPool.LeverageTooHigh.selector);
        perp.requestIncrease(true, 100 ether, 1_000 ether, 0, 0); // 40x
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ LP

    function testLpSharesPriceAgainstEquity() public {
        // 1:1 initial, less the MINIMUM_LIQUIDITY burned to 0xdead.
        assertEq(perp.sharesOf(lp), 100_000 ether - perp.MINIMUM_LIQUIDITY());
        assertEq(perp.sharesOf(address(0xdead)), perp.MINIMUM_LIQUIDITY());
        uint256 shares = _deposit(perp, keeper, 50_000 ether);
        assertEq(shares, 50_000 ether); // no PnL => still 1:1
        (LpStatus status, uint256 out) = _withdraw(perp, keeper, shares);
        assertEq(uint8(status), uint8(LpStatus.EXECUTED));
        assertEq(out, 50_000 ether);
        _accountingHolds(perp);
    }

    function testFirstDepositBurnsMinimumLiquidity() public {
        PerpPool fresh = _newPerp(FEE_PPM + 7, _params(100));
        uint256 floor = fresh.MINIMUM_LIQUIDITY();
        uint256 before = quote.balanceOf(lp);
        vm.prank(lp);
        uint256 id = fresh.requestDeposit(floor, 0, lp, lp, 0);
        vm.warp(_lpSettleAt(fresh, id));
        fresh.executeLp(id, _hints());
        (LpStatus status,,,) = fresh.lpRequestOutcome(id);
        assertEq(uint8(status), uint8(LpStatus.REFUNDED));
        assertEq(quote.balanceOf(lp), before, "dust first deposit refunded");

        uint256 shares = _deposit(fresh, lp, 10_000 ether);
        assertEq(shares, 10_000 ether - floor);
        assertEq(fresh.totalShares(), 10_000 ether);
        assertEq(fresh.sharesOf(address(0xdead)), floor);
    }

    function testWithdrawalLeavesTheExposureCovered() public {
        assertTrue(_open(trader, true, 10_000 ether, 15_000 ether)); // 60k notional vs ~100k equity
        uint256 shares = perp.sharesOf(lp);
        (LpStatus status,) = _withdraw(perp, lp, 90_000 ether);
        assertEq(uint8(status), uint8(LpStatus.REFUNDED));
        assertEq(perp.sharesOf(lp), shares, "shares returned");
        _accountingHolds(perp);
    }

    function testCancelLpOnlyByOwnerBeforeWindow() public {
        vm.prank(keeper);
        uint256 id = perp.requestDeposit(1_000 ether, 0, keeper, keeper, 0);
        vm.prank(trader);
        vm.expectRevert(PerpPool.NotRequestOwner.selector);
        perp.cancelLp(id);
        uint256 before = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.cancelLp(id);
        assertEq(quote.balanceOf(keeper) - before, 1_000 ether);

        vm.prank(lp);
        uint256 id2 = perp.requestWithdraw(1_000 ether, 0, lp, lp, 0);
        vm.warp(_lpSettleAt(perp, id2) - perp.MARK_WINDOW());
        vm.prank(lp);
        vm.expectRevert(PerpPool.WindowOpen.selector);
        perp.cancelLp(id2);
    }

    // ----------------------------------------------------------- positions

    function testOpenLongChargesFeeAndChecksLeverage() public {
        assertTrue(_open(trader, true, 1000 ether, 1000 ether)); // notional 4000
        (uint256 size, uint256 margin, uint256 entryNotional) = _pos(trader, true);
        assertEq(size, 1000 ether);
        uint256 notional = 4000 ether;
        uint256 fee = notional * FEE_PPM / 1e6;
        assertEq(margin, 1000 ether - fee);
        assertEq(entryNotional, notional);
        assertEq(perp.longSizeBase(), 1000 ether);
        assertGt(perp.protocolFeesQuote(), 0);
        _accountingHolds(perp);

        // 11x is past the 10x cap: refused at admission.
        vm.prank(keeper);
        vm.expectRevert(PerpPool.LeverageTooHigh.selector);
        perp.requestIncrease(true, 1000 ether, 2800 ether, 0, 0);
        _accountingHolds(perp);
    }

    function testOpenPositionUtilizationCap() public {
        // Side cap = 80% of ~100k equity = 80k notional => 20k base at price 4.
        vm.prank(trader);
        vm.expectRevert(PerpPool.UtilizationExceeded.selector);
        perp.requestIncrease(true, 30_000 ether, 25_000 ether, 0, 0); // 100k notional
    }

    function testLongProfitPaidFromVault() public {
        assertTrue(_open(trader, true, 10_000 ether, 5_000 ether)); // entry 4.0, notional 20k
        uint256 tlBefore = perp.totalLiquidity();

        _swap(true, 50_000 ether); // price up
        _rollMark();
        assertGt(perp.markX36(), 4e36);

        uint256 balBefore = quote.balanceOf(trader);
        assertTrue(_decrease(trader, true, 5_000 ether));
        uint256 payout = quote.balanceOf(trader) - balBefore;

        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        assertEq(perp.longSizeBase(), 0);
        assertGt(payout, 10_000 ether); // profit beyond margin despite fees
        assertLt(perp.totalLiquidity(), tlBefore);
        _accountingHolds(perp);
    }

    function testShortProfitOnPriceDrop() public {
        assertTrue(_open(trader, false, 10_000 ether, 5_000 ether));
        _swap(false, 20_000 ether); // dump base => price down
        _rollMark();
        uint256 balBefore = quote.balanceOf(trader);
        assertTrue(_decrease(trader, false, 5_000 ether));
        assertGt(quote.balanceOf(trader) - balBefore, 10_000 ether);
        _accountingHolds(perp);
    }

    function testPartialDecreaseKeepsProportions() public {
        // No funding, so the margin moves only with the decrease itself.
        perp = _newPerp(FEE_PPM + 3, _params(0));
        _deposit(perp, lp, 100_000 ether);
        assertTrue(_open(trader, true, 10_000 ether, 4_000 ether));
        (uint256 sizeBefore, uint256 marginBefore, uint256 notionalBefore) = _pos(trader, true);
        assertTrue(_decrease(trader, true, 1_000 ether));
        (uint256 size, uint256 margin, uint256 entryNotional) = _pos(trader, true);
        assertEq(size, sizeBefore - 1_000 ether);
        assertEq(entryNotional, notionalBefore - notionalBefore / 4);
        assertEq(margin, marginBefore - marginBefore / 4);
        _accountingHolds(perp);
    }

    function testDecreaseLargerThanPositionClosesIt() public {
        assertTrue(_open(trader, true, 10_000 ether, 1_000 ether));
        assertTrue(_decrease(trader, true, type(uint128).max));
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        _accountingHolds(perp);
    }

    // -------------------------------------------------------------- funding

    function testFundingAccruesFromHeavySideToVault() public {
        assertTrue(_open(trader, true, 10_000 ether, 5_000 ether)); // all-long book
        uint256 tlBefore = perp.totalLiquidity();
        (, uint256 marginBefore,) = _pos(trader, true);

        // A ten-hour jump in one go: the mark is a window ending now, so no
        // poking schedule is needed for funding to price correctly.
        vm.warp(block.timestamp + 10 hours);
        perp.updateFunding();
        assertGt(perp.cumFundingLongX36(), 0);
        assertEq(perp.cumFundingShortX36(), 0);

        // Touch the position to settle: margin down, vault up.
        vm.prank(trader);
        perp.addMargin(true, 1);
        (, uint256 marginAfter,) = _pos(trader, true);
        // 100% imbalance @100ppm/h for 10h on 20k notional ~= 20 quote.
        uint256 paid = marginBefore + 1 - marginAfter;
        assertApproxEqRel(paid, 20 ether, 1e15);
        assertEq(perp.totalLiquidity() - tlBefore, paid);
        _accountingHolds(perp);
    }

    function testBalancedBookNoFunding() public {
        // Requested together, so both sides open at the same instant.
        vm.prank(trader);
        perp.requestIncrease(true, 10_000 ether, 5_000 ether, 0, 0);
        vm.prank(keeper);
        perp.requestIncrease(false, 10_000 ether, 5_000 ether, 0, 0);
        assertTrue(_execute(perp, trader, true));
        assertTrue(_execute(perp, keeper, false));
        vm.warp(block.timestamp + 10 hours);
        perp.updateFunding();
        assertEq(perp.cumFundingLongX36(), 0);
        assertEq(perp.cumFundingShortX36(), 0);
    }

    // ----------------------------------------------------------- liquidation

    function testLiquidationFlow() public {
        // ~8x long: entry 4.0, notional 16k, margin 2k (fee shaves a bit).
        assertTrue(_open(trader, true, 2_048 ether, 4_000 ether));

        vm.prank(keeper);
        vm.expectRevert(PerpPool.NotLiquidatable.selector);
        perp.liquidate(trader, true);

        // Price ~10% lower => loss ~1.6k, equity ~0.4k < 5% maintenance on
        // ~14.4k notional, but still positive so a reward remains.
        _swap(false, 5_500 ether);
        _rollMark();
        uint256 tlBefore = perp.totalLiquidity();
        uint256 keeperBalBefore = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.liquidate(trader, true);

        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        assertEq(perp.longSizeBase(), 0);
        assertGt(quote.balanceOf(keeper) - keeperBalBefore, 0);
        assertGt(perp.totalLiquidity(), tlBefore); // forfeited margin -> vault
        _accountingHolds(perp);
    }

    function testBadDebtAbsorbedByVault() public {
        assertTrue(_open(trader, true, 1_030 ether, 2_500 ether)); // ~9.8x
        _swap(false, 30_000 ether); // massive dump
        _rollMark();

        uint256 keeperBefore = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.liquidate(trader, true);
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        // Equity is gone, so a pure cut of it would pay the liquidator
        // nothing and the position would sit there rotting. The notional
        // floor keeps the bounty alive.
        assertGt(quote.balanceOf(keeper) - keeperBefore, 0, "no bounty on a gapped position");
        _accountingHolds(perp);
    }

    function testLiquidationRewardFloorScalesWithNotional() public {
        assertTrue(_open(trader, true, 1_030 ether, 2_500 ether));
        _swap(false, 30_000 ether);
        _rollMark();

        uint256 mark = perp.markX36();
        (uint256 size,,) = _pos(trader, true);
        uint256 closeNotional = size * mark / 1e36;
        uint256 floor = closeNotional * perp.LIQ_REWARD_FLOOR_BPS() / 1e4;

        uint256 keeperBefore = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.liquidate(trader, true);
        assertEq(quote.balanceOf(keeper) - keeperBefore, floor);
        _accountingHolds(perp);
    }

    // ---------------------------------------------------------------- margin

    function testRemoveMarginGuards() public {
        assertTrue(_open(trader, true, 10_000 ether, 5_000 ether)); // 2x
        assertFalse(_removeMargin(trader, true, 8_500 ether), "would exceed 10x");
        assertTrue(_removeMargin(trader, true, 5_000 ether), "fine at ~4x");
        _accountingHolds(perp);
    }

    /// Margin can come out only against margin, not against a paper profit
    /// the vault has not paid.
    function testCannotWithdrawUnrealizedProfit() public {
        assertTrue(_open(trader, true, 2_100 ether, 5_000 ether)); // ~9.6x on margin
        _swap(true, 50_000 ether);
        _rollMark();
        assertGt(perp.equityOf(trader, true), 2_100 ether, "in profit");
        assertFalse(_removeMargin(trader, true, 200 ether));
    }

    // ---------------------------------------------------------------- misc

    function testCollectProtocolFees() public {
        assertTrue(_open(trader, true, 1_000 ether, 1_000 ether));
        uint256 fee = perp.protocolFeesQuote();
        assertGt(fee, 0);
        uint256 before = quote.balanceOf(address(treasury));
        perp.collectProtocolFees();
        assertEq(quote.balanceOf(address(treasury)) - before, fee);
        assertEq(perp.protocolFeesQuote(), 0);
        _accountingHolds(perp);
    }

    function testCreatePerpPoolValidation() public {
        vm.expectRevert(Pair.InvalidQuoteToken.selector);
        pair.createPerpPool(address(0xbeef), address(spot), FEE_PPM, PerpParams(10, 500, 100, 8000, 100));
        vm.expectRevert(Pair.UnknownSpotPool.selector);
        pair.createPerpPool(address(quote), address(0xbeef), FEE_PPM, PerpParams(10, 500, 100, 8000, 100));
        vm.expectRevert(PerpPool.InvalidPerpParams.selector);
        pair.createPerpPool(address(quote), address(spot), FEE_PPM + 1, PerpParams(51, 500, 100, 8000, 100));

        // Each bound passes alone, but 50x leaves 200bps of initial margin
        // against a 2000bps maintenance floor: liquidatable the block it
        // opens. The cross-check is what rejects it.
        vm.expectRevert(PerpPool.InvalidPerpParams.selector);
        pair.createPerpPool(address(quote), address(spot), FEE_PPM + 1, PerpParams(50, 2000, 100, 8000, 100));
        // Same leverage with a maintenance floor that actually fits is fine.
        pair.createPerpPool(address(quote), address(spot), FEE_PPM + 1, PerpParams(50, 100, 50, 8000, 100));
    }

    /// Only an identical configuration is a duplicate. Deduplicating on fee
    /// alone let the first creator fix the oracle and risk parameters of
    /// that fee for everyone after.
    function testOnlyIdenticalPerpConfigsCollide() public {
        vm.expectRevert(Pair.DuplicatePerpPool.selector);
        pair.createPerpPool(address(quote), address(spot), FEE_PPM, _params(100));
        // Same fee, different parameters: a separate market.
        pair.createPerpPool(address(quote), address(spot), FEE_PPM, _params(200));
        // Same fee, opposite quote token: also separate.
        pair.createPerpPool(address(base), address(spot), FEE_PPM, _params(100));
    }

    /// A quiet hour used to drop the mark, and a deposit then priced shares
    /// off `totalLiquidity` alone — handing a late LP part of what the vault
    /// had already won from a losing trader. A mark never lapses now, and a
    /// deposit settles at a later window's mark with the traders' PnL in.
    function testDepositAfterAQuietHourPaysForTheVaultsGains() public {
        assertTrue(_open(trader, true, 10_000 ether, 20_000 ether));
        // Trader deep in loss: real LP equity sits well above totalLiquidity.
        _swap(false, 2_000 ether);
        vm.warp(block.timestamp + 1 hours);

        uint256 supply = perp.totalShares();
        uint256 liquidity = perp.totalLiquidity();
        uint256 shares = _deposit(perp, keeper, 100_000 ether);
        // Fewer shares than a totalLiquidity-only price would have minted,
        // and they are worth what was deposited.
        assertLt(shares, 100_000 ether * supply / liquidity);
        assertApproxEqRel(shares * perp.lpEquityForDeposit() / perp.totalShares(), 100_000 ether, 1e12);
    }
}
