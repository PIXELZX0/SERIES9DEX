// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {MockERC20, MockBlocklistERC20} from "./mocks/MockERC20.sol";

/// A "pool" from a malicious factory. Its owner picks the reserves it
/// reports, so it can always look like the best venue; it takes whatever the
/// pair lets it and pays nothing back.
contract EvilPool {
    address public immutable pair;
    address public immutable token0;
    address public immutable token1;
    address public immutable thief;
    uint256 internal rb;
    uint256 internal rq;

    constructor(address pair_, address t0, address t1, address thief_) {
        pair = pair_;
        token0 = t0;
        token1 = t1;
        thief = thief_;
    }

    function setReserves(uint256 rb_, uint256 rq_) external {
        require(msg.sender == thief);
        (rb, rq) = (rb_, rq_);
    }

    function lpFeeRatePpm() external pure returns (uint32) {
        return 1;
    }

    function getReserves() external view returns (uint256, uint256, uint64) {
        return (rb, rq, 0);
    }

    function swapFromPair(address tokenIn, uint256 amountIn, uint256 minAmountOut, address) external returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, thief, amountIn);
        return tokenIn == token1 ? type(uint128).max : minAmountOut;
    }
}

contract EvilFactory {
    address public immutable thief;

    constructor(address thief_) {
        thief = thief_;
    }

    function deploy(address, address token0, address token1, uint32) external returns (address) {
        return address(new EvilPool(msg.sender, token0, token1, thief));
    }
}

/// Regression tests for the orderbook findings of the audit. Each one is the
/// original proof of concept turned around: the attack is attempted and the
/// test checks that it no longer works.
contract PairAuditTest is Test {
    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal lp = makeAddr("lp");
    address internal attacker = makeAddr("attacker");
    address internal thief = makeAddr("thief");
    uint64 internal expiry;

    function setUp() public {
        expiry = uint64(block.timestamp + 30 days);
    }

    function _registry(address spotFactory) internal returns (DexRegistry registry) {
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
        if (spotFactory == address(0)) spotFactory = address(new SpotPoolFactory(address(registry)));
        vm.prank(owner);
        registry.setFactories(spotFactory, address(0));
    }

    function _market(MockERC20 a, MockERC20 b) internal returns (Pair pair, SpotPool pool) {
        pair = Pair(_registry(address(0)).createPair(address(a), address(b)));
        pool = SpotPool(pair.createSpotPool(3000));
        _fund(pair, pool, MockERC20(pair.base()), MockERC20(pair.quote()));
    }

    function _fund(Pair pair, SpotPool pool, MockERC20 base, MockERC20 quote) internal {
        address[4] memory us = [seller, buyer, lp, attacker];
        for (uint256 i; i < us.length; i++) {
            base.mint(us[i], 1e30);
            quote.mint(us[i], 1e30);
            vm.startPrank(us[i]);
            base.approve(address(pair), type(uint256).max);
            quote.approve(address(pair), type(uint256).max);
            if (address(pool) != address(0)) {
                base.approve(address(pool), type(uint256).max);
                quote.approve(address(pool), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function _tokens(uint8 quoteDecimals) internal returns (MockERC20 base, MockERC20 quote) {
        // Retry until the 18-decimal token sorts first, so it is the base.
        while (true) {
            base = new MockERC20("BASE", "BASE", 18);
            quote = new MockERC20("QUOTE", "QUOTE", quoteDecimals);
            if (address(base) < address(quote)) return (base, quote);
        }
    }

    function _filled(Pair pair, uint256 id) internal view returns (uint256 f) {
        (,,,,,, f,,) = pair.orders(id);
    }

    // ----------------------------------------------------------------- M-1

    /// A one-wei ask at the highest price used to overflow the crossability
    /// check and revert every match on the pair. It now just never crosses.
    function test_absurdlyPricedAskCannotStopMatching() public {
        (MockERC20 base, MockERC20 quote) = _tokens(18);
        (Pair pair, SpotPool pool) = _market(base, quote);
        vm.prank(lp);
        pool.addLiquidity(10_000 ether, 40_000 ether, 0, 0, lp);

        uint256 maxPrice = pair.MAX_PRICE_X36(); // read before the prank, which a getter would consume
        vm.prank(attacker);
        pair.placeOrder(IPair.Side.SELL, maxPrice, 1, expiry, 0);
        pair.matchOrders(10);

        vm.prank(buyer);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, 4.5e36, 10 ether, expiry, 0);
        assertEq(_filled(pair, bidId), 10 ether, "crossable bid fills past the absurd ask");
        pair.matchOrders(10);
    }

    // ----------------------------------------------------------------- M-2

    /// A remainder worth less than one quote unit at the head of a crossed
    /// book used to stop every order behind it until its maker cancelled.
    /// It is now closed and refunded the moment matching reaches it.
    function test_dustRemainderCannotFreezeACrossedBook() public {
        // An 18-decimal base against a 6-decimal quote at $2: raw price 2e-12.
        (MockERC20 base, MockERC20 quote) = _tokens(6);
        (Pair pair, SpotPool pool) = _market(base, quote);
        vm.prank(lp);
        pool.addLiquidity(1_000_000 ether, 2_000_000e6, 0, 0, lp);
        uint256 price = 2e24;

        vm.startPrank(attacker);
        uint256 dustId = pair.placeOrder(IPair.Side.SELL, price, 1 ether + 1e9, expiry, 0);
        uint256 attackerBase = base.balanceOf(attacker);
        pair.placeOrder(IPair.Side.BUY, price, 1 ether, expiry, 0);
        vm.stopPrank();
        // 1e9 wei of base is worth 0.002 quote units: closed, not left behind.
        (,, IPair.Status dustStatus,,,,, uint256 dustEscrow,) = pair.orders(dustId);
        assertEq(uint8(dustStatus), uint8(IPair.Status.FILLED));
        assertEq(dustEscrow, 0);
        assertEq(base.balanceOf(attacker) - attackerBase, 1 ether + 1e9, "bought 1e18, refunded the dust");

        vm.prank(seller);
        uint256 askId = pair.placeOrder(IPair.Side.SELL, price, 100 ether, expiry, 0);
        vm.prank(buyer);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, 2.004e24, 100 ether, expiry, 0);
        assertEq(_filled(pair, askId), 100 ether, "honest ask fills");
        assertEq(_filled(pair, bidId), 100 ether, "honest bid fills");
    }

    /// Dust can also be left on the bid side; the same rule clears it.
    function test_dustBidIsClosedNotStuck() public {
        (MockERC20 base, MockERC20 quote) = _tokens(6);
        (Pair pair,) = _market(base, quote);
        uint256 price = 2e24;

        vm.prank(attacker);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, price, 1 ether + 1e9, expiry, 0);
        vm.prank(seller);
        pair.placeOrder(IPair.Side.SELL, price, 1 ether, expiry, 0);
        (,, IPair.Status status,,,,, uint256 escrow,) = pair.orders(bidId);
        assertEq(uint8(status), uint8(IPair.Status.FILLED));
        assertEq(escrow, 0);
        (uint256 bestBid,) = pair.bestBid();
        assertEq(bestBid, 0, "nothing left on the book");
    }

    // ----------------------------------------------------------------- M-3

    /// A marketable bid used to rest until someone else's swap triggered it,
    /// and that someone pushed the pool to the bid's limit first: the victim
    /// paid 4.97 for base the pool offered at 4.05. It now fills as placed.
    function test_marketableOrderFillsAtPlacementAndCannotBeSandwiched() public {
        (MockERC20 base, MockERC20 quote) = _tokens(18);
        (Pair pair, SpotPool pool) = _market(base, quote);
        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 400_000 ether, 0, 0, lp);

        uint256 q0 = quote.balanceOf(buyer);
        vm.prank(buyer);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, 5e36, 1000 ether, expiry, 0);
        assertEq(_filled(pair, bidId), 1000 ether);
        uint256 avgX18 = (q0 - quote.balanceOf(buyer)) * 1e18 / 1000 ether;
        assertLt(avgX18, 4.06e18, "filled near the pool, not at the limit");

        // The old sandwich now has nothing to fill and only pays fees.
        uint256 aq0 = quote.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 got = pool.swapExactIn(address(quote), 42_800 ether, 0, attacker);
        pool.swapExactIn(address(base), got, 0, attacker);
        vm.stopPrank();
        assertLt(quote.balanceOf(attacker), aq0, "round trip loses");
    }

    // ----------------------------------------------------------------- H-1

    /// Even a pool a malicious factory built cannot move escrow: the pair
    /// measures what left and what arrived, and a hop that does not pay is
    /// rolled back. (The other half of the fix — a factory change never
    /// reaching an existing pair — is in DexRegistry.t.sol.)
    function test_maliciousPoolCannotDrainEscrow() public {
        (MockERC20 base, MockERC20 quote) = _tokens(18);
        DexRegistry registry = _registry(address(new EvilFactory(thief)));
        Pair pair = Pair(registry.createPair(address(base), address(quote)));
        EvilPool evil = EvilPool(pair.createSpotPool(777));
        _fund(pair, SpotPool(address(0)), base, quote);

        vm.prank(thief);
        evil.setReserves(1e30, 1e36); // "price 1e6": best venue for any ask
        vm.prank(seller);
        uint256 askId = pair.placeOrder(IPair.Side.SELL, 5e36, 1000 ether, expiry, 0);
        vm.prank(thief);
        evil.setReserves(1e30, 2.99e30); // just under the bid
        vm.prank(buyer);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, 3e36, 1000 ether, expiry, 0);

        vm.prank(thief);
        pair.matchOrders(10);
        vm.prank(thief);
        evil.setReserves(1e30, 1e36);
        vm.prank(thief);
        pair.matchOrders(10);

        assertEq(base.balanceOf(thief), 0, "no ask escrow taken");
        assertEq(quote.balanceOf(thief), 0, "no bid escrow taken");
        assertEq(base.balanceOf(address(pair)), 1000 ether);
        assertEq(quote.balanceOf(address(pair)), 3000 ether);
        assertEq(_filled(pair, askId), 0);
        assertEq(_filled(pair, bidId), 0);
        assertEq(base.allowance(address(pair), address(evil)), 0, "no approval left behind");
        assertEq(quote.allowance(address(pair), address(evil)), 0, "no approval left behind");
    }

    // ----------------------------------------------------------------- M-7

    /// A pair whose raw price is 1e-17 now has six significant digits of
    /// price grid, where at 1e18 it had one.
    function test_lowPricedPairKeepsSixDigits() public {
        (MockERC20 base, MockERC20 quote) = _tokens(6);
        (Pair pair,) = _market(base, quote);
        assertEq(pair.tickSizeAt(1e19), 1e14); // 1e-5 of the price: six significant digits
        vm.startPrank(seller);
        pair.placeOrder(IPair.Side.SELL, 1.00001e19, 1e24, expiry, 0);
        pair.placeOrder(IPair.Side.SELL, 1.00002e19, 1e24, expiry, 0);
        vm.stopPrank();
        (uint256 bestAsk,) = pair.bestAsk();
        assertEq(bestAsk, 1.00001e19);
    }

    // ------------------------------------------------------- M-2 (review)

    /// WBTC(8)/USDC(6) at 60k: one satoshi is worth 0.0006 USDC, enough for
    /// the minimum notional, yet any pool fill of it rounds to nothing.
    function _btcMarket() internal returns (Pair pair, SpotPool pool, MockERC20 btc, MockERC20 usdc) {
        while (true) {
            btc = new MockERC20("BTC", "BTC", 8);
            usdc = new MockERC20("USDC", "USDC", 6);
            if (address(btc) < address(usdc)) break;
        }
        (pair, pool) = _market(btc, usdc);
        vm.prank(lp);
        pool.addLiquidity(10e8, 600_000e6, 0, 0, lp);
    }

    /// A one-satoshi ask at the head of the book used to read as "no pool
    /// crossable" and stop every ask behind it from filling against the
    /// pools. It is now closed as dust and matching goes on.
    function test_unitSizedAskCannotWedgeTheSide() public {
        (Pair pair, SpotPool pool, MockERC20 btc, MockERC20 usdc) = _btcMarket();
        vm.prank(attacker);
        uint256 wedge = pair.placeOrder(IPair.Side.SELL, 605e36, 1, expiry, 0); // 1 sat at 60.5k
        vm.prank(seller);
        uint256 honest = pair.placeOrder(IPair.Side.SELL, 610e36, 1e8, expiry, 0); // 1 BTC at 61k

        vm.prank(lp);
        pool.swapExactIn(address(usdc), 15_000e6, 0, lp); // pool to ~63k; its hook matches
        assertGt(_filled(pair, honest), 0, "the honest ask fills from the pool");
        (,, IPair.Status status,,,,, uint256 escrow,) = pair.orders(wedge);
        assertEq(uint8(status), uint8(IPair.Status.FILLED));
        assertEq(escrow, 0);
        assertEq(btc.balanceOf(attacker), 1e30, "the satoshi went home");
    }

    /// The bid-side wedge also left a marketable bid resting at placement,
    /// which is what made it sandwichable.
    function test_unitSizedBidCannotStallAMarketableBid() public {
        (Pair pair,,,) = _btcMarket();
        vm.prank(attacker);
        pair.placeOrder(IPair.Side.BUY, 1200e36, 1, expiry, 0); // 1 sat at 120k
        vm.prank(buyer);
        uint256 bid = pair.placeOrder(IPair.Side.BUY, 660e36, 5e7, expiry, 0); // 0.5 BTC at 66k
        (,, IPair.Status status,,,,,,) = pair.orders(bid);
        assertEq(uint8(status), uint8(IPair.Status.FILLED), "filled from the pool as placed");
    }

    /// Closing every head that failed against a pool with room for twice it
    /// still closed a $45 WBTC ask unfilled: pushed to just the right
    /// distance past its limit, a pool 100 BTC deep rounds away more than an
    /// order that size gains. Only remainders under `DUST_UNITS` are closed
    /// now; this one waits and fills once the pool moves on.
    function test_legitSmallOrderWaitsInsteadOfBeingClosed() public {
        (Pair pair, SpotPool pool, MockERC20 btc, MockERC20 usdc) = _btcMarket();
        vm.prank(lp);
        pool.addLiquidity(90e8, 5_400_000e6, 0, 0, lp); // 100 BTC deep
        uint256 limit = 603e36; // 60,300
        uint256 dx = 75_776; // ~$45.7
        vm.prank(seller);
        uint256 id = pair.placeOrder(IPair.Side.SELL, limit, dx, expiry, 0);

        // The smallest swap that leaves the pool room for twice the order.
        uint256 lo;
        uint256 hi = 1e12;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_sellRoomAfter(pool, limit, mid) >= 2 * dx) hi = mid;
            else lo = mid + 1;
        }
        vm.prank(attacker);
        pool.swapExactIn(address(usdc), lo + 3_000, 0, attacker); // its hook matches
        (,, IPair.Status status,,,, uint256 filled, uint256 escrow,) = pair.orders(id);
        assertEq(uint8(status), uint8(IPair.Status.OPEN), "still on the book");
        assertEq(filled, 0);
        assertEq(escrow, dx);

        vm.prank(attacker);
        pool.swapExactIn(address(usdc), 50_000e6, 0, attacker);
        assertEq(_filled(pair, id), dx, "fills once the pool moves on");
        assertEq(btc.balanceOf(address(pair)), 0);
    }

    /// Room at `limit` for a sell into `pool` after `quoteIn` more is swapped
    /// in, as `Pair._bestPool` measures it.
    function _sellRoomAfter(SpotPool pool, uint256 limit, uint256 quoteIn) internal view returns (uint256) {
        (uint256 reserveBase, uint256 reserveQuote,) = pool.getReserves();
        uint256 out = pool.getAmountOut(pool.token1(), quoteIn);
        uint256 protocolFee = Math.ceilDiv(Math.mulDiv(quoteIn, 3000, 1e6, Math.Rounding.Ceil), 1000);
        uint256 cap = Math.mulDiv(reserveQuote + quoteIn - protocolFee, 1e36, limit);
        uint256 floorTerm = Math.mulDiv(reserveBase - out, 1e6, 997_000, Math.Rounding.Ceil);
        return cap > floorTerm ? cap - floorTerm : 0;
    }

    // ----------------------------------------------------------------- M-8

    /// A maker the quote token refuses used to revert every match on the
    /// pair. Their proceeds and refunds now wait in `claimable`, matching
    /// carries on, and they can claim to an address the token accepts.
    function test_blockedMakerCannotStopMatching() public {
        MockERC20 base;
        MockBlocklistERC20 quote;
        while (true) {
            base = new MockERC20("BASE", "BASE", 18);
            quote = new MockBlocklistERC20(18);
            if (address(base) < address(quote)) break;
        }
        (Pair pair, SpotPool pool) = _market(base, MockERC20(address(quote)));
        vm.prank(lp);
        pool.addLiquidity(10_000 ether, 40_000 ether, 0, 0, lp);

        // Two resting asks; the first maker is then blocklisted.
        vm.prank(attacker);
        uint256 blockedAsk = pair.placeOrder(IPair.Side.SELL, 4.1e36, 10 ether, expiry, 0);
        vm.prank(seller);
        uint256 honestAsk = pair.placeOrder(IPair.Side.SELL, 4.1e36, 10 ether, expiry, 0);
        quote.setBlocked(attacker, true);

        // A buy lifts the pool past both asks; its auto-match fills them.
        vm.prank(lp);
        pool.swapExactIn(address(quote), 2_000 ether, 0, lp);
        pair.matchOrders(10);
        assertEq(_filled(pair, blockedAsk), 10 ether);
        assertEq(_filled(pair, honestAsk), 10 ether, "the next maker still fills");

        uint256 owed = pair.claimable(attacker, address(quote));
        assertGt(owed, 41 ether);
        assertEq(pair.totalClaimable(address(quote)), owed);

        address elsewhere = makeAddr("elsewhere");
        vm.prank(attacker);
        pair.claim(address(quote), elsewhere);
        assertEq(quote.balanceOf(elsewhere), owed);
        assertEq(pair.claimable(attacker, address(quote)), 0);

        // A refund to a blocked maker defers the same way instead of making
        // the order impossible to close.
        vm.prank(buyer);
        uint256 bidId = pair.placeOrder(IPair.Side.BUY, 3e36, 10 ether, expiry, 0);
        quote.setBlocked(buyer, true);
        vm.prank(buyer);
        pair.cancelOrder(bidId);
        assertEq(pair.claimable(buyer, address(quote)), 30 ether);
    }
}
