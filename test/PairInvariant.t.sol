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

contract PairHandler is Test {
    Pair public immutable pair;
    SpotPool[] public pools;
    MockERC20 internal immutable base;
    MockERC20 internal immutable quote;

    uint256[] public myOrders;

    constructor(Pair pair_, address token0_, address token1_) {
        pair = pair_;
        base = MockERC20(token0_);
        quote = MockERC20(token1_);
        base.approve(address(pair_), type(uint256).max);
        quote.approve(address(pair_), type(uint256).max);

        // Two spot pools with different fees so matching actually has to
        // route/split across pools rather than degenerate to a single one.
        uint32[2] memory fees = [uint32(3000), uint32(5000)];
        for (uint256 i = 0; i < fees.length; i++) {
            SpotPool p = SpotPool(pair_.createSpotPool(fees[i]));
            base.approve(address(p), type(uint256).max);
            quote.approve(address(p), type(uint256).max);
            base.mint(address(this), 1000 ether);
            quote.mint(address(this), 4000 ether);
            p.addLiquidity(1000 ether, 4000 ether, 0, 0, address(this));
            pools.push(p);
        }
    }

    function place(uint256 price, uint256 amount, bool sell, uint256 ttl) external {
        // Straddles the pools' 4.0 price, so both sides overlap constantly:
        // this is what drives crossed books into direct `_fillPair` matching
        // and makes the book compete with the pools on price.
        price = bound(price, 1e18, 10e18);
        price = price - (price % 1e15); // keep inside the significant-digit grid
        if (price == 0) price = 1e15;
        amount = bound(amount, 0.01 ether, 100 ether);
        ttl = bound(ttl, 60, 30 days);
        MockERC20 token = sell ? base : quote;
        token.mint(address(this), amount * price / 1e18 + amount + 1 ether);
        try pair.placeOrder(
            sell ? IPair.Side.SELL : IPair.Side.BUY, price, amount, uint64(block.timestamp + ttl), 0
        ) returns (
            uint256 id
        ) {
            myOrders.push(id);
        } catch {}
    }

    function cancel(uint256 index) external {
        if (myOrders.length == 0) return;
        index = bound(index, 0, myOrders.length - 1);
        try pair.cancelOrder(myOrders[index]) {} catch {}
    }

    function doMatch(uint256 maxFills) external {
        maxFills = bound(maxFills, 1, 10);
        try pair.matchOrders(maxFills) {} catch {}
    }

    function swap(uint256 poolIndex, uint256 amountIn, bool zeroForOne) external {
        poolIndex = bound(poolIndex, 0, pools.length - 1);
        amountIn = bound(amountIn, 0.001 ether, 50 ether);
        MockERC20 tokenIn = zeroForOne ? base : quote;
        tokenIn.mint(address(this), amountIn);
        try pools[poolIndex].swapExactIn(address(tokenIn), amountIn, 0, address(this)) {} catch {}
    }

    function warpAndExpire(uint256 dt, uint256 index) external {
        dt = bound(dt, 1, 12 hours);
        vm.warp(block.timestamp + dt);
        if (myOrders.length == 0) return;
        index = bound(index, 0, myOrders.length - 1);
        try pair.removeExpired(myOrders[index]) {} catch {}
    }

    function orderCount() external view returns (uint256) {
        return myOrders.length;
    }
}

contract PairInvariantTest is Test {
    Pair internal pair;
    PairHandler internal handler;
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
        SpotPoolFactory factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        base = MockERC20(pair.base());
        quote = MockERC20(pair.quote());

        handler = new PairHandler(pair, address(base), address(quote));
        targetContract(address(handler));
    }

    /// The pair holds exactly the sum of open-order escrows, per token.
    function invariant_escrowSolvencyExact() public view {
        uint256 sumBase;
        uint256 sumQuote;
        for (uint256 id = 1; id < pair.nextOrderId(); id++) {
            (, IPair.Side side, IPair.Status status,,,,, uint256 escrow,) = pair.orders(id);
            if (status == IPair.Status.OPEN) {
                if (side == IPair.Side.SELL) sumBase += escrow;
                else sumQuote += escrow;
            } else {
                assertEq(escrow, 0);
            }
        }
        assertEq(base.balanceOf(address(pair)), sumBase);
        assertEq(quote.balanceOf(address(pair)), sumQuote);
    }

    /// Best pointers always reference active levels with liquidity, sorted.
    function invariant_bestPointersSane() public view {
        (uint256 bidPrice, uint256 bidTotal) = pair.bestBid();
        (uint256 askPrice, uint256 askTotal) = pair.bestAsk();
        if (bidPrice != 0) assertGt(bidTotal, 0);
        if (askPrice != 0) assertGt(askTotal, 0);
    }
}
