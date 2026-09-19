// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Direct book-to-book matching: a crossed pair must fill against each other
/// rather than being routed through the AMM, unless the AMM is genuinely the
/// better side at that moment.
contract PairBookMatchTest is Test {
    DexRegistry internal registry;
    Pair internal pair;
    SpotPool internal pool;
    MockERC20 internal base;
    MockERC20 internal quote;

    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal lp = makeAddr("lp");
    uint64 internal expiry;

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
        SpotPoolFactory f = new SpotPoolFactory(address(registry));
        vm.prank(owner);
        registry.setFactories(address(f), address(0));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (base, quote) = address(a) < address(b) ? (a, b) : (b, a);
        pair = Pair(registry.createPair(address(base), address(quote)));
        pool = SpotPool(pair.createSpotPool(3000));
        expiry = uint64(block.timestamp + 30 days);

        address[3] memory us = [seller, buyer, lp];
        for (uint256 i; i < us.length; i++) {
            base.mint(us[i], 10_000_000 ether);
            quote.mint(us[i], 10_000_000 ether);
            vm.startPrank(us[i]);
            base.approve(address(pool), type(uint256).max);
            quote.approve(address(pool), type(uint256).max);
            base.approve(address(pair), type(uint256).max);
            quote.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seed(uint256 poolBase, uint256 poolQuote) internal {
        vm.prank(lp);
        pool.addLiquidity(poolBase, poolQuote, 0, 0, lp);
    }

    function _filled(uint256 id) internal view returns (uint256 f) {
        (,,,,,, f,,) = pair.orders(id);
    }

    function _avgX18(uint256 quoteAmt, uint256 baseAmt) internal pure returns (uint256) {
        return quoteAmt * 1e18 / baseAmt;
    }

    /// The case that motivated this: a thin pool used to relay the two orders
    /// through itself and the buyer paid ~4.7145 for base the book was
    /// offering at 4.50. Now they meet at the 4.75 midpoint and the pool takes
    /// no cut of it.
    function testCrossedPairFillsAtMidpoint() public {
        _seed(10 ether, 40 ether); // price 4.0, far too thin to fill 100

        uint256 sellerQuoteBefore = quote.balanceOf(seller);
        uint256 buyerQuoteBefore = quote.balanceOf(buyer);
        uint256 buyerBaseBefore = base.balanceOf(buyer);

        vm.prank(seller);
        uint256 sellId = pair.placeOrder(IPair.Side.SELL, 4.5e18, 100 ether, expiry, 0);
        vm.prank(buyer);
        uint256 buyId = pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

        assertEq(_filled(buyId), 100 ether);

        uint256 sellerGot = quote.balanceOf(seller) - sellerQuoteBefore;
        uint256 buyerPaid = buyerQuoteBefore - quote.balanceOf(buyer);
        assertEq(base.balanceOf(buyer) - buyerBaseBefore, 100 ether);

        uint256 sold = _filled(sellId);
        assertGt(sold, 99 ether);

        uint256 buyerAvg = _avgX18(buyerPaid, 100 ether);
        uint256 sellerAvg = _avgX18(sellerGot, sold);
        // Each side strictly inside its own limit, and both at the midpoint.
        assertLe(buyerAvg, 5e18);
        assertGe(sellerAvg, 4.5e18);
        assertApproxEqRel(buyerAvg, 4.75e18, 1e15);
        assertApproxEqRel(sellerAvg, 4.75e18, 1e15);
        console.log("buyer avg  (milli):", buyerAvg / 1e15);
        console.log("seller avg (milli):", sellerAvg / 1e15);
    }

    /// Same fill, opposite arrival order: the midpoint does not move.
    function testArrivalOrderDoesNotMoveThePrice() public {
        _seed(10 ether, 40 ether);
        uint256 buyerQuoteBefore = quote.balanceOf(buyer);
        uint256 sellerQuoteBefore = quote.balanceOf(seller);

        vm.prank(buyer);
        uint256 buyId = pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        vm.prank(seller);
        uint256 sellId = pair.placeOrder(IPair.Side.SELL, 4.5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

        assertEq(_filled(buyId), 100 ether);
        uint256 sold = _filled(sellId);
        assertGt(sold, 99 ether);

        uint256 sellerAvg = _avgX18(quote.balanceOf(seller) - sellerQuoteBefore, sold);
        uint256 buyerAvg = _avgX18(buyerQuoteBefore - quote.balanceOf(buyer), 100 ether);
        // Identical to the resting-ask case above.
        assertApproxEqRel(sellerAvg, 4.75e18, 1e15);
        assertApproxEqRel(buyerAvg, 4.75e18, 1e15);
        console.log("buyer avg  (milli):", buyerAvg / 1e15);
        console.log("seller avg (milli):", sellerAvg / 1e15);
    }

    /// The regression a naive "book first" rule would cause: with a deep pool
    /// at 4.0 the buyer must still take the pool, not the 4.5 ask.
    function testPoolWinsWhenItIsCheaperThanTheBook() public {
        _seed(10_000 ether, 40_000 ether); // price 4.0, deep

        uint256 buyerQuoteBefore = quote.balanceOf(buyer);
        vm.prank(seller);
        uint256 sellId = pair.placeOrder(IPair.Side.SELL, 4.5e18, 100 ether, expiry, 0);
        vm.prank(buyer);
        uint256 buyId = pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

        assertEq(_filled(buyId), 100 ether);
        uint256 buyerPaid = buyerQuoteBefore - quote.balanceOf(buyer);
        // Well under the 450 the resting ask wanted: the pool was cheaper.
        assertLt(buyerPaid, 420 ether);
        // The ask is above the pool's price, so it correctly stays unfilled.
        assertEq(_filled(sellId), 0);
        console.log("buyer paid via pool:", buyerPaid / 1e15);
    }

    /// With no pool liquidity at all the book still clears itself, which it
    /// could not do before.
    function testCrossedPairFillsWithNoPoolLiquidity() public {
        vm.prank(seller);
        uint256 sellId = pair.placeOrder(IPair.Side.SELL, 4.5e18, 100 ether, expiry, 0);
        vm.prank(buyer);
        uint256 buyId = pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

        assertEq(_filled(sellId), 100 ether);
        assertEq(_filled(buyId), 100 ether);
    }

    /// Partial fill: the smaller side closes, the larger keeps its remainder
    /// and its escrow.
    function testPartialCrossLeavesRemainder() public {
        vm.prank(seller);
        uint256 sellId = pair.placeOrder(IPair.Side.SELL, 4.5e18, 30 ether, expiry, 0);
        vm.prank(buyer);
        uint256 buyId = pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

        assertEq(_filled(sellId), 30 ether);
        assertEq(_filled(buyId), 30 ether);
        (,, IPair.Status buyStatus,,,,, uint256 buyEscrow,) = pair.orders(buyId);
        assertEq(uint8(buyStatus), uint8(IPair.Status.OPEN));
        // 500 escrowed, 142.5 spent: 30 base at the 4.75 midpoint.
        assertEq(buyEscrow, 357.5 ether);
        (uint256 askPrice, uint256 askTotal) = pair.bestAsk();
        assertEq(askPrice, 0); // ask side cleared
        assertEq(askTotal, 0);
        (, uint256 bidTotal) = pair.bestBid();
        assertEq(bidTotal, 70 ether);
    }

    /// Escrow solvency must hold across a direct fill.
    function testEscrowSolvencyAfterDirectFill() public {
        vm.prank(seller);
        pair.placeOrder(IPair.Side.SELL, 4.5e18, 30 ether, expiry, 0);
        vm.prank(buyer);
        pair.placeOrder(IPair.Side.BUY, 5e18, 100 ether, expiry, 0);
        pair.matchOrders(50);

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

    // ------------------------------------------------------- levels() cursor

    /// A cursor handed back by `levels()` can be gone by the next call — anyone
    /// may match, and a filled level is unlinked. Trusting the dead cursor
    /// returned an empty page, which a paging front end reads as "no more
    /// depth" while the book still has plenty.
    function testLevelsCursorSurvivesItsLevelBeingFilled() public {
        // No pool, so the crossed book has to clear itself and the levels the
        // bid reaches are genuinely consumed rather than undercut by the AMM.
        vm.startPrank(seller);
        pair.placeOrder(IPair.Side.SELL, 4.1e18, 1 ether, expiry, 0);
        pair.placeOrder(IPair.Side.SELL, 4.2e18, 2 ether, expiry, 0);
        pair.placeOrder(IPair.Side.SELL, 4.3e18, 3 ether, expiry, 0);
        vm.stopPrank();

        (uint256[] memory prices,, uint256 cursor) = pair.levels(IPair.Side.SELL, 0, 1);
        assertEq(prices[0], 4.1e18);
        assertEq(cursor, 4.2e18);

        // The level the cursor points at is filled and unlinked before the
        // front end comes back for page two. A 4.25 bid crosses 4.1 and 4.2 but
        // not 4.3.
        vm.prank(buyer);
        pair.placeOrder(IPair.Side.BUY, 4.25e18, 3 ether, expiry, 0);
        pair.matchOrders(20);
        (bool stillActive,,) = pair.levelOf(IPair.Side.SELL, 4.2e18);
        assertFalse(stillActive, "4.2 level must be gone for this to test anything");

        // The remaining 4.3 depth is still reported rather than lost.
        (prices,, cursor) = pair.levels(IPair.Side.SELL, 4.2e18, 10);
        assertGt(prices.length, 0, "dead cursor must not read as an empty book");
        assertEq(prices[prices.length - 1], 4.3e18);
        assertEq(cursor, 0); // genuinely exhausted now
    }

    function testGridViewsAgree() public view {
        // The tick reported at a magnitude must be exactly the step that stays
        // on the grid, for both views computed from one walk.
        uint256[3] memory samples = [uint256(4.5e18), 999999, 1e21];
        for (uint256 i; i < samples.length; i++) {
            uint256 tick = pair.tickSizeAt(samples[i]);
            assertTrue(pair.priceIsValid(samples[i] - (samples[i] % tick)));
            if (tick > 1) assertFalse(pair.priceIsValid(samples[i] - (samples[i] % tick) + 1));
        }
    }
}
