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
    /// through itself, and the buyer paid ~4.71 for base the book offered at
    /// 4.50. Now the resting ask sets the price and the pool is not involved.
    function testCrossedPairFillsAtRestingPrice() public {
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

        // The pool holds a sliver of base priced under the 4.5 ask, and taking
        // that first is correct — it is genuinely cheaper. The rest comes from
        // the book at the resting ask.
        uint256 fromBook = _filled(sellId);
        assertGt(fromBook, 99 ether);

        // Both sides land inside their own limits, and the buyer's average is
        // at most the resting ask — where the AMM relay used to charge 4.7145
        // for this exact pair.
        uint256 buyerAvg = _avgX18(buyerPaid, 100 ether);
        uint256 sellerAvg = _avgX18(sellerGot, fromBook);
        assertLe(buyerAvg, 4.5e18);
        assertGe(sellerAvg, 4.5e18 - 1);
        assertLt(buyerAvg, 4.7145e18); // strictly better than the old routing
        console.log("buyer avg  (milli):", buyerAvg / 1e15);
        console.log("seller avg (milli):", sellerAvg / 1e15);
    }

    /// Symmetric: when the bid is the resting order, it sets the price.
    function testRestingBidSetsThePrice() public {
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

        // The book leg settles at the resting bid's 5.0, so the seller clears
        // well above their own 4.5 ask — the mirror of the previous test.
        uint256 sellerAvg = _avgX18(quote.balanceOf(seller) - sellerQuoteBefore, sold);
        uint256 buyerAvg = _avgX18(buyerQuoteBefore - quote.balanceOf(buyer), 100 ether);
        assertGt(sellerAvg, 4.9e18);
        assertLe(buyerAvg, 5e18);
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
        // 500 escrowed, 135 spent at 4.5.
        assertEq(buyEscrow, 365 ether);
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
}
