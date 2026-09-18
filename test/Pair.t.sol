// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PairTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    Pair internal pair;
    SpotPool internal pool;
    MockERC20 internal base; // token0
    MockERC20 internal quote; // token1

    address internal owner = makeAddr("owner");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal lp = makeAddr("lp");

    uint32 internal constant FEE_PPM = 3000;
    uint64 internal expiry;

    function setUp() public {
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
        SpotPoolFactory factory = new SpotPoolFactory(address(registry));
        vm.prank(owner);
        registry.setFactories(address(factory), address(0));

        // Deploy two tokens and force deterministic ordering via new addresses.
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (base, quote) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        pair = Pair(registry.createPair(address(base), address(quote)));
        pool = SpotPool(pair.createSpotPool(FEE_PPM));
        expiry = uint64(block.timestamp + 1 days);

        address[3] memory users = [maker, taker, lp];
        for (uint256 i = 0; i < users.length; i++) {
            base.mint(users[i], 1_000_000 ether);
            quote.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            base.approve(address(pool), type(uint256).max);
            quote.approve(address(pool), type(uint256).max);
            base.approve(address(pair), type(uint256).max);
            quote.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }
        // Pool at price 4.0 (quote per base).
        vm.prank(lp);
        pool.addLiquidity(100 ether, 400 ether, 0, 0, lp);
    }

    function _placeSell(uint256 price, uint256 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = pair.placeOrder(IPair.Side.SELL, price, amount, expiry, 0);
    }

    function _placeBuy(uint256 price, uint256 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = pair.placeOrder(IPair.Side.BUY, price, amount, expiry, 0);
    }

    function _order(uint256 id)
        internal
        view
        returns (IPair.Status status, uint256 filledBase, uint256 escrowRemaining)
    {
        (,, status,,,, filledBase, escrowRemaining,) = pair.orders(id);
    }

    // ----------------------------------------------------------- placement

    function testPlaceSellEscrowsBase() public {
        uint256 balBefore = base.balanceOf(maker);
        _placeSell(4.5e18, 10 ether);
        assertEq(balBefore - base.balanceOf(maker), 10 ether);
        assertEq(base.balanceOf(address(pair)), 10 ether);
        (uint256 price, uint256 total) = pair.bestAsk();
        assertEq(price, 4.5e18);
        assertEq(total, 10 ether);
    }

    function testPlaceBuyEscrowsQuoteCeil() public {
        uint256 balBefore = quote.balanceOf(maker);
        _placeBuy(3.5e18, 10 ether);
        assertEq(balBefore - quote.balanceOf(maker), 35 ether);
        (uint256 price, uint256 total) = pair.bestBid();
        assertEq(price, 3.5e18);
        assertEq(total, 10 ether);
    }

    function testPlaceOrderValidation() public {
        vm.startPrank(maker);
        vm.expectRevert(Pair.InvalidPrice.selector);
        pair.placeOrder(IPair.Side.SELL, 4e18 + 1, 1 ether, expiry, 0);
        vm.expectRevert(Pair.InvalidExpiry.selector);
        pair.placeOrder(IPair.Side.SELL, 4e18, 1 ether, uint64(block.timestamp), 0);
        vm.expectRevert(Pair.NotionalTooSmall.selector);
        pair.placeOrder(IPair.Side.SELL, 1e15, 1e3, expiry, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------- cancel/expire

    function testCancelRefundsExactly() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        uint256 balBefore = base.balanceOf(maker);
        vm.prank(maker);
        pair.cancelOrder(id);
        assertEq(base.balanceOf(maker) - balBefore, 10 ether);
        (IPair.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.CANCELLED));
        assertEq(escrow, 0);
        (uint256 price,) = pair.bestAsk();
        assertEq(price, 0); // level unlinked
    }

    function testCancelOnlyMaker() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        vm.prank(taker);
        vm.expectRevert(Pair.NotMaker.selector);
        pair.cancelOrder(id);
    }

    function testCancelTwiceReverts() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        vm.startPrank(maker);
        pair.cancelOrder(id);
        vm.expectRevert(Pair.OrderNotOpen.selector);
        pair.cancelOrder(id);
        vm.stopPrank();
    }

    function testRemoveExpired() public {
        uint256 id = _placeBuy(3.5e18, 10 ether);
        vm.prank(taker);
        vm.expectRevert(Pair.OrderNotExpired.selector);
        pair.removeExpired(id);
        vm.warp(expiry);
        uint256 balBefore = quote.balanceOf(maker);
        vm.prank(taker); // anyone
        pair.removeExpired(id);
        assertEq(quote.balanceOf(maker) - balBefore, 35 ether);
        (IPair.Status status,,) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.EXPIRED));
    }

    // ------------------------------------------------------------- levels

    function testLevelOrdering() public {
        _placeSell(4.6e18, 1 ether);
        _placeSell(4.4e18, 1 ether);
        _placeSell(4.5e18, 1 ether);
        (uint256 bestAskPrice,) = pair.bestAsk();
        assertEq(bestAskPrice, 4.4e18);
        (,, uint256 next) = pair.levelOf(IPair.Side.SELL, 4.4e18);
        assertEq(next, 4.5e18);
        (,, next) = pair.levelOf(IPair.Side.SELL, 4.5e18);
        assertEq(next, 4.6e18);

        _placeBuy(3.4e18, 1 ether);
        _placeBuy(3.6e18, 1 ether);
        (uint256 bestBidPrice,) = pair.bestBid();
        assertEq(bestBidPrice, 3.6e18);
        (,, next) = pair.levelOf(IPair.Side.BUY, 3.6e18);
        assertEq(next, 3.4e18);
    }

    function testLevelInsertWithHint() public {
        _placeSell(4.4e18, 1 ether);
        _placeSell(4.8e18, 1 ether);
        vm.prank(maker);
        pair.placeOrder(IPair.Side.SELL, 4.6e18, 1 ether, expiry, 4.4e18);
        (,, uint256 next) = pair.levelOf(IPair.Side.SELL, 4.4e18);
        assertEq(next, 4.6e18);
    }

    // ------------------------------------------------------------ matching

    function testMatchSellFullFill() public {
        // Pool price 4.0 with fee => marginal bid ~3.988. Sell limit 3.9 is crossable.
        uint256 id = _placeSell(3.9e18, 1 ether);
        uint256 quoteBefore = quote.balanceOf(maker);
        pair.matchOrders(10);
        (IPair.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.FILLED));
        assertEq(escrow, 0);
        // Maker received at least the limit price per base.
        assertGe(quote.balanceOf(maker) - quoteBefore, 3.9 ether);
        assertEq(base.balanceOf(address(pair)), 0);
    }

    function testMatchSellPartialFillLandsAtLimit() public {
        // Big order: pool can only absorb ~0.96 base before hitting 3.95.
        uint256 id = _placeSell(3.95e18, 50 ether);
        uint256 quoteBefore = quote.balanceOf(maker);
        pair.matchOrders(10);
        (IPair.Status status, uint256 filled, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.OPEN));
        assertGt(filled, 0.9 ether);
        assertLt(filled, 1.1 ether);
        assertEq(escrow, 50 ether - filled);
        // Average execution price >= limit.
        uint256 received = quote.balanceOf(maker) - quoteBefore;
        assertGe(received * 1e18, filled * 3.95e18);
        // Second match is a no-op: the single pool sits exactly at the limit.
        pair.matchOrders(10);
        (, uint256 filledAfter,) = _order(id);
        assertEq(filledAfter, filled);
    }

    function testMatchBuyFullFill() public {
        // Pool ask with fee ~4.012 < 4.1 limit => crossable.
        uint256 baseBefore = base.balanceOf(maker);
        uint256 quoteBefore = quote.balanceOf(maker);
        uint256 id = _placeBuy(4.1e18, 1 ether);
        pair.matchOrders(10);
        (IPair.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.FILLED));
        assertEq(escrow, 0);
        uint256 baseGot = base.balanceOf(maker) - baseBefore;
        assertGe(baseGot, 1 ether);
        // Net cost (escrow minus refund) stays within the limit price.
        uint256 spent = quoteBefore - quote.balanceOf(maker);
        assertLe(spent, 4.1 ether + 1);
        assertEq(quote.balanceOf(address(pair)), 0);
    }

    function testMatchNotCrossableNoop() public {
        uint256 sellId = _placeSell(4.5e18, 1 ether); // above pool bid
        uint256 buyId = _placeBuy(3.5e18, 1 ether); // below pool ask
        pair.matchOrders(10);
        (IPair.Status s1,,) = _order(sellId);
        (IPair.Status s2,,) = _order(buyId);
        assertEq(uint8(s1), uint8(IPair.Status.OPEN));
        assertEq(uint8(s2), uint8(IPair.Status.OPEN));
    }

    function testMatchFifoWithinLevel() public {
        uint256 first = _placeSell(3.9e18, 0.3 ether);
        vm.prank(taker);
        uint256 second = pair.placeOrder(IPair.Side.SELL, 3.9e18, 0.3 ether, expiry, 0);
        pair.matchOrders(1); // only one fill allowed
        (IPair.Status s1,,) = _order(first);
        (IPair.Status s2,,) = _order(second);
        assertEq(uint8(s1), uint8(IPair.Status.FILLED));
        assertEq(uint8(s2), uint8(IPair.Status.OPEN));
    }

    function testMatchSkipsExpiredAndRefunds() public {
        uint256 id = _placeSell(3.9e18, 1 ether);
        vm.warp(expiry);
        uint256 balBefore = base.balanceOf(maker);
        pair.matchOrders(10);
        (IPair.Status status,,) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.EXPIRED));
        assertEq(base.balanceOf(maker) - balBefore, 1 ether);
    }

    function testMatchFromPoolOnlyPool() public {
        vm.expectRevert(Pair.OnlySpotPool.selector);
        pair.matchFromPool(5);
    }

    // -------------------------------------------------------- auto-matching

    function testSwapAutoFillsCrossedOrder() public {
        // Not crossable at pool price 4.0 (bid w/ fee ~3.988).
        uint256 id = _placeSell(4.05e18, 0.5 ether);
        (IPair.Status statusBefore,,) = _order(id);
        assertEq(uint8(statusBefore), uint8(IPair.Status.OPEN));

        // Taker buys base with 10 quote: pool price rises past the limit,
        // post-swap hook fills the resting order in the same tx.
        vm.prank(taker);
        pool.swapExactIn(address(quote), 10 ether, 0, taker);

        (IPair.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.FILLED));
        assertEq(escrow, 0);
    }

    // ---------------------------------------------------- multi-pool routing

    function testMatchSellSplitsAcrossPools() public {
        // Second pool, same depth as the first (fee must differ, at least by
        // 1ppm, to satisfy the one-pool-per-fee rule — negligible for the
        // routing math below) — the greedy router should exhaust one pool
        // down to the limit price, then hop to the other.
        address pool2Addr = pair.createSpotPool(FEE_PPM + 1);
        SpotPool pool2 = SpotPool(pool2Addr);
        vm.startPrank(lp);
        base.approve(pool2Addr, type(uint256).max);
        quote.approve(pool2Addr, type(uint256).max);
        pool2.addLiquidity(100 ether, 400 ether, 0, 0, lp);
        vm.stopPrank();

        (uint256 r0Before1,,) = pool.getReserves();
        (uint256 r0Before2,,) = pool2.getReserves();

        uint256 id = _placeSell(3.95e18, 50 ether);
        pair.matchOrders(10);

        (uint256 r0After1,,) = pool.getReserves();
        (uint256 r0After2,,) = pool2.getReserves();
        assertGt(r0After1, r0Before1); // pool 1 absorbed base
        assertGt(r0After2, r0Before2); // pool 2 absorbed base too -> order split across pools

        (IPair.Status status, uint256 filled,) = _order(id);
        assertEq(uint8(status), uint8(IPair.Status.OPEN));
        // Roughly double the single-pool capacity from testMatchSellPartialFillLandsAtLimit.
        assertGt(filled, 1.8 ether);
        assertLt(filled, 2.1 ether);
    }

    function testMatchBuySplitsAcrossPools() public {
        address pool2Addr = pair.createSpotPool(FEE_PPM + 1);
        SpotPool pool2 = SpotPool(pool2Addr);
        vm.startPrank(lp);
        base.approve(pool2Addr, type(uint256).max);
        quote.approve(pool2Addr, type(uint256).max);
        pool2.addLiquidity(100 ether, 400 ether, 0, 0, lp);
        vm.stopPrank();

        (, uint256 r1Before1,) = pool.getReserves();
        (, uint256 r1Before2,) = pool2.getReserves();

        _placeBuy(4.05e18, 50 ether);
        pair.matchOrders(10);

        (, uint256 r1After1,) = pool.getReserves();
        (, uint256 r1After2,) = pool2.getReserves();
        assertGt(r1After1, r1Before1); // pool 1 absorbed quote
        assertGt(r1After2, r1Before2); // pool 2 absorbed quote too -> order split across pools
    }

    // ------------------------------------------------------------- solvency

    function testEscrowSolvencyAfterMixedActivity() public {
        _placeSell(3.9e18, 2 ether);
        _placeSell(4.2e18, 3 ether);
        _placeBuy(4.1e18, 1 ether);
        uint256 farBuy = _placeBuy(3.3e18, 2 ether); // never crossable here
        pair.matchOrders(10);
        vm.prank(maker);
        pair.cancelOrder(farBuy);

        // Sum open escrows == balances.
        uint256 sumBase;
        uint256 sumQuote;
        for (uint256 id = 1; id < pair.nextOrderId(); id++) {
            (, IPair.Side side, IPair.Status status,,,,, uint256 escrow,) = pair.orders(id);
            if (status == IPair.Status.OPEN) {
                if (side == IPair.Side.SELL) sumBase += escrow;
                else sumQuote += escrow;
            }
        }
        assertEq(base.balanceOf(address(pair)), sumBase);
        assertEq(quote.balanceOf(address(pair)), sumQuote);
    }

    // ------------------------------------------------------- price grid

    function testPriceGridAcceptsSixSignificantDigits() public view {
        assertTrue(pair.priceIsValid(4.5e18));
        assertTrue(pair.priceIsValid(123456e12)); // 1.23456 at X18
        assertTrue(pair.priceIsValid(10)); // tiny-scale pair, every integer legal
        assertTrue(pair.priceIsValid(999999));
        assertFalse(pair.priceIsValid(0));
        assertFalse(pair.priceIsValid(4.5e18 + 1));
        assertFalse(pair.priceIsValid(1234567e12)); // seven digits
    }

    function testTickSizeAtTracksMagnitude() public view {
        assertEq(pair.tickSizeAt(4.5e18), 1e13);
        assertEq(pair.tickSizeAt(999999), 1);
        assertEq(pair.tickSizeAt(1e21), 1e16);
    }

    function testOffGridPriceRejected() public {
        vm.prank(maker);
        vm.expectRevert(Pair.InvalidPrice.selector);
        pair.placeOrder(IPair.Side.SELL, 4.5e18 + 1, 10 ether, expiry, 0);
    }

    // --------------------------------------------------- dead-node budget

    /// Cancelled FIFO nodes must be charged against `maxFills`. Without that,
    /// a level stuffed behind one live order makes every later match walk all
    /// of them for free, and past ~30k nodes no call can ever finish.
    function testDeadNodesConsumeFillBudget() public {
        uint256 price = 4.5e18;
        uint256[] memory dead = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            dead[i] = _placeSell(price, 1 ether);
        }
        // Live order at the tail keeps totalBase > 0, so the level survives
        // the cancels and the dead nodes stay queued in front of it.
        uint256 live = _placeSell(price, 10 ether);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(maker);
            pair.cancelOrder(dead[i]);
        }

        // Cross the level, which also runs the swap's own auto-match with a
        // budget of MAX_AUTO_FILLS (5) — exactly the five dead nodes.
        vm.prank(lp);
        pool.swapExactIn(address(quote), 50 ether, 0, lp);
        (uint256 ask,) = pair.bestAsk();
        assertEq(ask, price);
        (, uint256 filled,) = _order(live);
        assertEq(filled, 0, "budget went to pops, not to the live order");

        // The backlog is gone for good, so the next unit of budget reaches
        // the live order instead of re-walking the dead ones.
        pair.matchOrders(1);
        (, filled,) = _order(live);
        assertGt(filled, 0);
    }

    // -------------------------------------------------------------- views

    function testOrdersOfPaginates() public {
        uint256 a = _placeSell(4.5e18, 10 ether);
        uint256 b = _placeSell(4.6e18, 10 ether);
        uint256 c = _placeBuy(3.5e18, 10 ether);
        assertEq(pair.ordersOfLength(maker), 3);

        (uint256[] memory ids, Pair.Order[] memory page) = pair.ordersOf(maker, 0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(page[0].priceX18, 4.5e18);
        assertEq(uint8(page[1].side), uint8(IPair.Side.SELL));

        (ids, page) = pair.ordersOf(maker, 2, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], c);
        assertEq(uint8(page[0].side), uint8(IPair.Side.BUY));

        (ids, page) = pair.ordersOf(maker, 99, 10);
        assertEq(ids.length, 0);
        assertEq(page.length, 0);
    }

    function testLevelsWalkBookOutward() public {
        _placeSell(4.5e18, 1 ether);
        _placeSell(4.7e18, 2 ether);
        _placeSell(4.6e18, 3 ether);

        (uint256[] memory prices, uint256[] memory totals, uint256 cursor) = pair.levels(IPair.Side.SELL, 0, 2);
        assertEq(prices.length, 2);
        assertEq(prices[0], 4.5e18); // best ask first
        assertEq(prices[1], 4.6e18);
        assertEq(totals[1], 3 ether);
        assertEq(cursor, 4.7e18);

        (prices, totals, cursor) = pair.levels(IPair.Side.SELL, cursor, 10);
        assertEq(prices.length, 1);
        assertEq(prices[0], 4.7e18);
        assertEq(totals[0], 2 ether);
        assertEq(cursor, 0); // side exhausted
    }

    function testLevelsOnEmptySideIsEmpty() public view {
        (uint256[] memory prices,, uint256 cursor) = pair.levels(IPair.Side.BUY, 0, 5);
        assertEq(prices.length, 0);
        assertEq(cursor, 0);
    }
}
