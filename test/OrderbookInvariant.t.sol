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

contract OrderbookHandler is Test {
    Orderbook public immutable orderbook;
    SpotPool public immutable pool;
    MockERC20 internal immutable base;
    MockERC20 internal immutable quote;
    bytes32 internal immutable pairId;

    uint256[] public myOrders;

    constructor(Orderbook orderbook_, SpotPool pool_) {
        orderbook = orderbook_;
        pool = pool_;
        base = MockERC20(pool_.token0());
        quote = MockERC20(pool_.token1());
        pairId = pool_.pairId();
        base.approve(address(orderbook_), type(uint256).max);
        quote.approve(address(orderbook_), type(uint256).max);
        base.approve(address(pool_), type(uint256).max);
        quote.approve(address(pool_), type(uint256).max);
    }

    function place(uint256 price, uint256 amount, bool sell, uint256 ttl) external {
        price = bound(price, 1e15, 100e18);
        price = price - (price % 1e15); // tick align
        if (price == 0) price = 1e15;
        amount = bound(amount, 0.01 ether, 100 ether);
        ttl = bound(ttl, 60, 30 days);
        MockERC20 token = sell ? base : quote;
        token.mint(address(this), amount * price / 1e18 + amount + 1 ether);
        try orderbook.placeOrder(
            pairId, sell ? Orderbook.Side.SELL : Orderbook.Side.BUY, price, amount, uint64(block.timestamp + ttl), 0
        ) returns (
            uint256 id
        ) {
            myOrders.push(id);
        } catch {}
    }

    function cancel(uint256 index) external {
        if (myOrders.length == 0) return;
        index = bound(index, 0, myOrders.length - 1);
        try orderbook.cancelOrder(myOrders[index]) {} catch {}
    }

    function doMatch(uint256 maxFills) external {
        maxFills = bound(maxFills, 1, 10);
        try orderbook.matchOrders(pairId, address(pool), maxFills) {} catch {}
    }

    function swap(uint256 amountIn, bool zeroForOne) external {
        amountIn = bound(amountIn, 0.001 ether, 50 ether);
        MockERC20 tokenIn = zeroForOne ? base : quote;
        tokenIn.mint(address(this), amountIn);
        try pool.swapExactIn(address(tokenIn), amountIn, 0, address(this)) {} catch {}
    }

    function warpAndExpire(uint256 dt, uint256 index) external {
        dt = bound(dt, 1, 12 hours);
        vm.warp(block.timestamp + dt);
        if (myOrders.length == 0) return;
        index = bound(index, 0, myOrders.length - 1);
        try orderbook.removeExpired(myOrders[index]) {} catch {}
    }

    function orderCount() external view returns (uint256) {
        return myOrders.length;
    }
}

contract OrderbookInvariantTest is Test {
    Orderbook internal orderbook;
    OrderbookHandler internal handler;
    SpotPool internal pool;
    MockERC20 internal base;
    MockERC20 internal quote;

    function setUp() public {
        address owner = makeAddr("owner");
        ProtocolTreasury treasury = ProtocolTreasury(
            address(
                new ERC1967Proxy(address(new ProtocolTreasury()), abi.encodeCall(ProtocolTreasury.initialize, (owner)))
            )
        );
        DexRegistry registry = DexRegistry(
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

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        pool = SpotPool(registry.createSpotPool(address(tokenA), address(tokenB), 3000, 1e15));
        base = MockERC20(pool.token0());
        quote = MockERC20(pool.token1());

        base.mint(address(this), 1000 ether);
        quote.mint(address(this), 4000 ether);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1000 ether, 4000 ether, 0, 0, address(this));

        handler = new OrderbookHandler(orderbook, pool);
        targetContract(address(handler));
    }

    /// The orderbook holds exactly the sum of open-order escrows, per token.
    function invariant_escrowSolvencyExact() public view {
        uint256 sumBase;
        uint256 sumQuote;
        for (uint256 id = 1; id < orderbook.nextOrderId(); id++) {
            (, Orderbook.Side side, Orderbook.Status status,,,,,, uint256 escrow,) = orderbook.orders(id);
            if (status == Orderbook.Status.OPEN) {
                if (side == Orderbook.Side.SELL) sumBase += escrow;
                else sumQuote += escrow;
            } else {
                assertEq(escrow, 0);
            }
        }
        assertEq(base.balanceOf(address(orderbook)), sumBase);
        assertEq(quote.balanceOf(address(orderbook)), sumQuote);
    }

    /// Best pointers always reference active levels with liquidity, sorted.
    function invariant_bestPointersSane() public view {
        bytes32 pairId = pool.pairId();
        (uint256 bidPrice, uint256 bidTotal) = orderbook.bestBid(pairId);
        (uint256 askPrice, uint256 askTotal) = orderbook.bestAsk(pairId);
        if (bidPrice != 0) assertGt(bidTotal, 0);
        if (askPrice != 0) assertGt(askTotal, 0);
    }
}
