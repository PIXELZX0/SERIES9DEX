// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Orderbook} from "../src/Orderbook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OrderbookTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    Orderbook internal orderbook;
    SpotPool internal pool;
    MockERC20 internal base; // token0
    MockERC20 internal quote; // token1
    bytes32 internal pairId;

    address internal owner = makeAddr("owner");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal lp = makeAddr("lp");

    uint32 internal constant FEE_PPM = 3000;
    uint256 internal constant TICK = 1e15;
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
        orderbook = new Orderbook(address(registry));
        SpotPoolFactory factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setOrderbook(address(orderbook));
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        // Deploy two tokens and force deterministic ordering via new addresses.
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (base, quote) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        pool = SpotPool(registry.createSpotPool(address(base), address(quote), FEE_PPM, TICK));
        pairId = pool.pairId();
        expiry = uint64(block.timestamp + 1 days);

        address[3] memory users = [maker, taker, lp];
        for (uint256 i = 0; i < users.length; i++) {
            base.mint(users[i], 1_000_000 ether);
            quote.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            base.approve(address(pool), type(uint256).max);
            quote.approve(address(pool), type(uint256).max);
            base.approve(address(orderbook), type(uint256).max);
            quote.approve(address(orderbook), type(uint256).max);
            vm.stopPrank();
        }
        // Pool at price 4.0 (quote per base).
        vm.prank(lp);
        pool.addLiquidity(100 ether, 400 ether, 0, 0, lp);
    }

    function _placeSell(uint256 price, uint256 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = orderbook.placeOrder(pairId, Orderbook.Side.SELL, price, amount, expiry, 0);
    }

    function _placeBuy(uint256 price, uint256 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = orderbook.placeOrder(pairId, Orderbook.Side.BUY, price, amount, expiry, 0);
    }

    function _order(uint256 id)
        internal
        view
        returns (Orderbook.Status status, uint256 filledBase, uint256 escrowRemaining)
    {
        (,, status,,,,, filledBase, escrowRemaining,) = orderbook.orders(id);
    }

    // ----------------------------------------------------------- placement

    function testPlaceSellEscrowsBase() public {
        uint256 balBefore = base.balanceOf(maker);
        _placeSell(4.5e18, 10 ether);
        assertEq(balBefore - base.balanceOf(maker), 10 ether);
        assertEq(base.balanceOf(address(orderbook)), 10 ether);
        (uint256 price, uint256 total) = orderbook.bestAsk(pairId);
        assertEq(price, 4.5e18);
        assertEq(total, 10 ether);
    }

    function testPlaceBuyEscrowsQuoteCeil() public {
        uint256 balBefore = quote.balanceOf(maker);
        _placeBuy(3.5e18, 10 ether);
        assertEq(balBefore - quote.balanceOf(maker), 35 ether);
        (uint256 price, uint256 total) = orderbook.bestBid(pairId);
        assertEq(price, 3.5e18);
        assertEq(total, 10 ether);
    }

    function testPlaceOrderValidation() public {
        vm.startPrank(maker);
        vm.expectRevert(Orderbook.BookNotInitialized.selector);
        orderbook.placeOrder(bytes32("nope"), Orderbook.Side.SELL, 4e18, 1 ether, expiry, 0);
        vm.expectRevert(Orderbook.InvalidPrice.selector);
        orderbook.placeOrder(pairId, Orderbook.Side.SELL, 4e18 + 1, 1 ether, expiry, 0);
        vm.expectRevert(Orderbook.InvalidExpiry.selector);
        orderbook.placeOrder(pairId, Orderbook.Side.SELL, 4e18, 1 ether, uint64(block.timestamp), 0);
        vm.expectRevert(Orderbook.NotionalTooSmall.selector);
        orderbook.placeOrder(pairId, Orderbook.Side.SELL, 1e15, 1e3, expiry, 0);
        vm.stopPrank();
    }

    function testInitBookOnlyRegistry() public {
        vm.expectRevert(Orderbook.OnlyRegistry.selector);
        orderbook.initBook(bytes32("x"), address(base), address(quote), TICK);
    }

    // ------------------------------------------------------- cancel/expire

    function testCancelRefundsExactly() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        uint256 balBefore = base.balanceOf(maker);
        vm.prank(maker);
        orderbook.cancelOrder(id);
        assertEq(base.balanceOf(maker) - balBefore, 10 ether);
        (Orderbook.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.CANCELLED));
        assertEq(escrow, 0);
        (uint256 price,) = orderbook.bestAsk(pairId);
        assertEq(price, 0); // level unlinked
    }

    function testCancelOnlyMaker() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        vm.prank(taker);
        vm.expectRevert(Orderbook.NotMaker.selector);
        orderbook.cancelOrder(id);
    }

    function testCancelTwiceReverts() public {
        uint256 id = _placeSell(4.5e18, 10 ether);
        vm.startPrank(maker);
        orderbook.cancelOrder(id);
        vm.expectRevert(Orderbook.OrderNotOpen.selector);
        orderbook.cancelOrder(id);
        vm.stopPrank();
    }

    function testRemoveExpired() public {
        uint256 id = _placeBuy(3.5e18, 10 ether);
        vm.prank(taker);
        vm.expectRevert(Orderbook.OrderNotExpired.selector);
        orderbook.removeExpired(id);
        vm.warp(expiry);
        uint256 balBefore = quote.balanceOf(maker);
        vm.prank(taker); // anyone
        orderbook.removeExpired(id);
        assertEq(quote.balanceOf(maker) - balBefore, 35 ether);
        (Orderbook.Status status,,) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.EXPIRED));
    }

    // ------------------------------------------------------------- levels

    function testLevelOrdering() public {
        _placeSell(4.6e18, 1 ether);
        _placeSell(4.4e18, 1 ether);
        _placeSell(4.5e18, 1 ether);
        (uint256 bestAskPrice,) = orderbook.bestAsk(pairId);
        assertEq(bestAskPrice, 4.4e18);
        (,, uint256 next) = orderbook.levelOf(pairId, Orderbook.Side.SELL, 4.4e18);
        assertEq(next, 4.5e18);
        (,, next) = orderbook.levelOf(pairId, Orderbook.Side.SELL, 4.5e18);
        assertEq(next, 4.6e18);

        _placeBuy(3.4e18, 1 ether);
        _placeBuy(3.6e18, 1 ether);
        (uint256 bestBidPrice,) = orderbook.bestBid(pairId);
        assertEq(bestBidPrice, 3.6e18);
        (,, next) = orderbook.levelOf(pairId, Orderbook.Side.BUY, 3.6e18);
        assertEq(next, 3.4e18);
    }

    function testLevelInsertWithHint() public {
        _placeSell(4.4e18, 1 ether);
        _placeSell(4.8e18, 1 ether);
        vm.prank(maker);
        orderbook.placeOrder(pairId, Orderbook.Side.SELL, 4.6e18, 1 ether, expiry, 4.4e18);
        (,, uint256 next) = orderbook.levelOf(pairId, Orderbook.Side.SELL, 4.4e18);
        assertEq(next, 4.6e18);
    }

    // ------------------------------------------------------------ matching

    function testMatchSellFullFill() public {
        // Pool price 4.0 with fee => marginal bid ~3.988. Sell limit 3.9 is crossable.
        uint256 id = _placeSell(3.9e18, 1 ether);
        uint256 quoteBefore = quote.balanceOf(maker);
        orderbook.matchOrders(pairId, address(pool), 10);
        (Orderbook.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.FILLED));
        assertEq(escrow, 0);
        // Maker received at least the limit price per base.
        assertGe(quote.balanceOf(maker) - quoteBefore, 3.9 ether);
        assertEq(base.balanceOf(address(orderbook)), 0);
    }

    function testMatchSellPartialFillLandsAtLimit() public {
        // Big order: pool can only absorb ~0.96 base before hitting 3.95.
        uint256 id = _placeSell(3.95e18, 50 ether);
        uint256 quoteBefore = quote.balanceOf(maker);
        orderbook.matchOrders(pairId, address(pool), 10);
        (Orderbook.Status status, uint256 filled, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.OPEN));
        assertGt(filled, 0.9 ether);
        assertLt(filled, 1.1 ether);
        assertEq(escrow, 50 ether - filled);
        // Average execution price >= limit.
        uint256 received = quote.balanceOf(maker) - quoteBefore;
        assertGe(received * 1e18, filled * 3.95e18);
        // Second match is a no-op: pool sits exactly at the limit.
        orderbook.matchOrders(pairId, address(pool), 10);
        (, uint256 filledAfter,) = _order(id);
        assertEq(filledAfter, filled);
    }

    function testMatchBuyFullFill() public {
        // Pool ask with fee ~4.012 < 4.1 limit => crossable.
        uint256 baseBefore = base.balanceOf(maker);
        uint256 quoteBefore = quote.balanceOf(maker);
        uint256 id = _placeBuy(4.1e18, 1 ether);
        orderbook.matchOrders(pairId, address(pool), 10);
        (Orderbook.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.FILLED));
        assertEq(escrow, 0);
        uint256 baseGot = base.balanceOf(maker) - baseBefore;
        assertGe(baseGot, 1 ether);
        // Net cost (escrow minus refund) stays within the limit price.
        uint256 spent = quoteBefore - quote.balanceOf(maker);
        assertLe(spent, 4.1 ether + 1);
        assertEq(quote.balanceOf(address(orderbook)), 0);
    }

    function testMatchNotCrossableNoop() public {
        uint256 sellId = _placeSell(4.5e18, 1 ether); // above pool bid
        uint256 buyId = _placeBuy(3.5e18, 1 ether); // below pool ask
        orderbook.matchOrders(pairId, address(pool), 10);
        (Orderbook.Status s1,,) = _order(sellId);
        (Orderbook.Status s2,,) = _order(buyId);
        assertEq(uint8(s1), uint8(Orderbook.Status.OPEN));
        assertEq(uint8(s2), uint8(Orderbook.Status.OPEN));
    }

    function testMatchFifoWithinLevel() public {
        uint256 first = _placeSell(3.9e18, 0.3 ether);
        vm.prank(taker);
        uint256 second = orderbook.placeOrder(pairId, Orderbook.Side.SELL, 3.9e18, 0.3 ether, expiry, 0);
        orderbook.matchOrders(pairId, address(pool), 1); // only one fill allowed
        (Orderbook.Status s1,,) = _order(first);
        (Orderbook.Status s2,,) = _order(second);
        assertEq(uint8(s1), uint8(Orderbook.Status.FILLED));
        assertEq(uint8(s2), uint8(Orderbook.Status.OPEN));
    }

    function testMatchSkipsExpiredAndRefunds() public {
        uint256 id = _placeSell(3.9e18, 1 ether);
        vm.warp(expiry);
        uint256 balBefore = base.balanceOf(maker);
        orderbook.matchOrders(pairId, address(pool), 10);
        (Orderbook.Status status,,) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.EXPIRED));
        assertEq(base.balanceOf(maker) - balBefore, 1 ether);
    }

    function testMatchInvalidPoolReverts() public {
        vm.expectRevert(Orderbook.InvalidPool.selector);
        orderbook.matchOrders(pairId, address(0xbeef), 10);
    }

    function testMatchFromPoolOnlyPool() public {
        vm.expectRevert(Orderbook.OnlySpotPool.selector);
        orderbook.matchFromPool(pairId, 5);
    }

    // -------------------------------------------------------- auto-matching

    function testSwapAutoFillsCrossedOrder() public {
        // Not crossable at pool price 4.0 (bid w/ fee ~3.988).
        uint256 id = _placeSell(4.05e18, 0.5 ether);
        (Orderbook.Status statusBefore,,) = _order(id);
        assertEq(uint8(statusBefore), uint8(Orderbook.Status.OPEN));

        // Taker buys base with 10 quote: pool price rises past the limit,
        // post-swap hook fills the resting order in the same tx.
        vm.prank(taker);
        pool.swapExactIn(address(quote), 10 ether, 0, taker);

        (Orderbook.Status status,, uint256 escrow) = _order(id);
        assertEq(uint8(status), uint8(Orderbook.Status.FILLED));
        assertEq(escrow, 0);
    }

    // ------------------------------------------------------------- solvency

    function testEscrowSolvencyAfterMixedActivity() public {
        _placeSell(3.9e18, 2 ether);
        _placeSell(4.2e18, 3 ether);
        _placeBuy(4.1e18, 1 ether);
        uint256 farBuy = _placeBuy(3.3e18, 2 ether); // never crossable here
        orderbook.matchOrders(pairId, address(pool), 10);
        vm.prank(maker);
        orderbook.cancelOrder(farBuy);

        // Sum open escrows == balances.
        uint256 sumBase;
        uint256 sumQuote;
        for (uint256 id = 1; id < orderbook.nextOrderId(); id++) {
            (, Orderbook.Side side, Orderbook.Status status,,,,,, uint256 escrow,) = orderbook.orders(id);
            if (status == Orderbook.Status.OPEN) {
                if (side == Orderbook.Side.SELL) sumBase += escrow;
                else sumQuote += escrow;
            }
        }
        assertEq(base.balanceOf(address(orderbook)), sumBase);
        assertEq(quote.balanceOf(address(orderbook)), sumQuote);
    }
}
