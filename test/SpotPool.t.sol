// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./mocks/MockERC20.sol";
import {MockOrderbook} from "./mocks/MockOrderbook.sol";

contract SpotPoolTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    MockOrderbook internal orderbook;
    SpotPool internal pool;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint32 internal constant FEE_PPM = 3000; // 0.3%

    function setUp() public {
        ProtocolTreasury treasuryImpl = new ProtocolTreasury();
        treasury = ProtocolTreasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(ProtocolTreasury.initialize, (owner))))
        );
        DexRegistry registryImpl = new DexRegistry();
        registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl), abi.encodeCall(DexRegistry.initialize, (owner, address(treasury)))
                )
            )
        );
        orderbook = new MockOrderbook();
        SpotPoolFactory factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setOrderbook(address(orderbook));
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        pool = SpotPool(registry.createSpotPool(address(tokenA), address(tokenB), FEE_PPM, 1e15));

        for (uint256 i = 0; i < 2; i++) {
            MockERC20 t = i == 0 ? token0 : token1;
            t.mint(alice, 1_000_000 ether);
            t.mint(bob, 1_000_000 ether);
            vm.prank(alice);
            t.approve(address(pool), type(uint256).max);
            vm.prank(bob);
            t.approve(address(pool), type(uint256).max);
        }
    }

    function _addLiquidity(address who, uint256 amt0, uint256 amt1) internal returns (uint256 liquidity) {
        vm.prank(who);
        (liquidity,,) = pool.addLiquidity(amt0, amt1, 0, 0, who);
    }

    // ------------------------------------------------------------ liquidity

    function testFirstMintLocksMinimumLiquidity() public {
        uint256 liquidity = _addLiquidity(alice, 100 ether, 400 ether);
        assertEq(liquidity, Math.sqrt(100 ether * 400 ether) - pool.MINIMUM_LIQUIDITY());
        assertEq(pool.balanceOf(address(0xdead)), pool.MINIMUM_LIQUIDITY());
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertEq(r0, 100 ether);
        assertEq(r1, 400 ether);
    }

    function testSecondAddMatchesRatio() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        // Bob offers excess token1; pool should take the ratio-matched amount.
        uint256 bal1Before = token1.balanceOf(bob);
        vm.prank(bob);
        (, uint256 used0, uint256 used1) = pool.addLiquidity(50 ether, 999 ether, 50 ether, 200 ether, bob);
        assertEq(used0, 50 ether);
        assertEq(used1, 200 ether);
        assertEq(bal1Before - token1.balanceOf(bob), 200 ether);
    }

    function testAddLiquiditySlippageReverts() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        vm.prank(bob);
        vm.expectRevert(SpotPool.SlippageExceeded.selector);
        pool.addLiquidity(50 ether, 999 ether, 50 ether, 201 ether, bob);
    }

    function testRemoveLiquidityProportional() public {
        uint256 liquidity = _addLiquidity(alice, 100 ether, 400 ether);
        uint256 bal0Before = token0.balanceOf(alice);
        uint256 bal1Before = token1.balanceOf(alice);
        vm.prank(alice);
        (uint256 amt0, uint256 amt1) = pool.removeLiquidity(liquidity, 0, 0, alice);
        // Alice gets everything except the dead-locked share.
        assertApproxEqRel(amt0, 100 ether, 1e12);
        assertApproxEqRel(amt1, 400 ether, 1e12);
        assertEq(token0.balanceOf(alice) - bal0Before, amt0);
        assertEq(token1.balanceOf(alice) - bal1Before, amt1);
    }

    // ----------------------------------------------------------------- swap

    function testSwapMatchesGetAmountOutAndFeeSplit() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        uint256 amountIn = 10 ether;
        uint256 expectedOut = pool.getAmountOut(address(token0), amountIn);

        uint256 totalFee = amountIn * FEE_PPM / 1e6;
        uint256 protocolFee = totalFee / 1000;
        uint256 effIn = amountIn - totalFee;
        assertEq(expectedOut, 400 ether * effIn / (100 ether + effIn));

        vm.prank(bob);
        uint256 out = pool.swapExactIn(address(token0), amountIn, expectedOut, bob);
        assertEq(out, expectedOut);
        assertEq(pool.protocolFees0(), protocolFee);
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertEq(r0, 100 ether + amountIn - protocolFee);
        assertEq(r1, 400 ether - out);
    }

    function testSwapKNeverDecreases() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        (uint256 r0, uint256 r1,) = pool.getReserves();
        uint256 kBefore = r0 * r1;
        vm.prank(bob);
        pool.swapExactIn(address(token1), 25 ether, 0, bob);
        (r0, r1,) = pool.getReserves();
        assertGe(r0 * r1, kBefore);
    }

    function testSwapMinOutReverts() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        uint256 expectedOut = pool.getAmountOut(address(token0), 10 ether);
        vm.prank(bob);
        vm.expectRevert(SpotPool.InsufficientOutput.selector);
        pool.swapExactIn(address(token0), 10 ether, expectedOut + 1, bob);
    }

    function testSwapInvalidTokenReverts() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        MockERC20 other = new MockERC20("X", "X", 18);
        other.mint(bob, 1 ether);
        vm.startPrank(bob);
        other.approve(address(pool), type(uint256).max);
        vm.expectRevert(SpotPool.InvalidToken.selector);
        pool.swapExactIn(address(other), 1 ether, 0, bob);
        vm.stopPrank();
    }

    function testSwapEmptyPoolReverts() public {
        vm.prank(bob);
        vm.expectRevert(SpotPool.InsufficientLiquidity.selector);
        pool.swapExactIn(address(token0), 1 ether, 0, bob);
    }

    // ------------------------------------------------------------------ hook

    function testSwapTriggersAutoMatchHook() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        vm.prank(bob);
        pool.swapExactIn(address(token0), 1 ether, 0, bob);
        assertEq(orderbook.matchCalls(), 1);
        assertEq(orderbook.lastPairId(), pool.pairId());
        assertEq(orderbook.lastMaxFills(), pool.MAX_AUTO_FILLS());
    }

    function testHookRevertDoesNotRevertSwap() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        orderbook.setRevertOnMatch(true);
        vm.prank(bob);
        uint256 out = pool.swapExactIn(address(token0), 1 ether, 0, bob);
        assertGt(out, 0);
        assertEq(orderbook.matchCalls(), 0);
    }

    function testSwapFromOrderbookOnlyOrderbook() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        vm.prank(bob);
        vm.expectRevert(SpotPool.OnlyOrderbook.selector);
        pool.swapFromOrderbook(address(token0), 1 ether, 0, bob);
    }

    function testSwapFromOrderbookDoesNotRecurse() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        token0.mint(address(orderbook), 10 ether);
        vm.startPrank(address(orderbook));
        token0.approve(address(pool), type(uint256).max);
        pool.swapFromOrderbook(address(token0), 1 ether, 0, address(orderbook));
        vm.stopPrank();
        assertEq(orderbook.matchCalls(), 0);
    }

    // ------------------------------------------------------------------ fees

    function testCollectProtocolFees() public {
        _addLiquidity(alice, 100 ether, 400 ether);
        vm.prank(bob);
        pool.swapExactIn(address(token0), 100 ether, 0, bob);
        uint256 fee0 = pool.protocolFees0();
        assertGt(fee0, 0);
        pool.collectProtocolFees();
        assertEq(pool.protocolFees0(), 0);
        assertEq(token0.balanceOf(address(treasury)), fee0);
    }

    // ------------------------------------------------------------------ TWAP

    function testTwapAccumulates() public {
        _addLiquidity(alice, 100 ether, 400 ether); // price0 = 4e18
        uint256 cumBefore = pool.price0CumulativeLast();
        vm.warp(block.timestamp + 100);
        vm.prank(bob);
        pool.swapExactIn(address(token0), 1 ether, 0, bob);
        uint256 cumAfter = pool.price0CumulativeLast();
        assertEq(cumAfter - cumBefore, 4e18 * 100);
    }

    // -------------------------------------------------------- fee-on-transfer

    function testFeeOnTransferSwapCreditsDelta() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20(100); // 1%
        MockERC20 plain = new MockERC20("P", "P", 18);
        SpotPool fotPool = SpotPool(registry.createSpotPool(address(fot), address(plain), FEE_PPM, 1e15));

        fot.mint(alice, 1000 ether);
        plain.mint(alice, 1000 ether);
        vm.startPrank(alice);
        fot.approve(address(fotPool), type(uint256).max);
        plain.approve(address(fotPool), type(uint256).max);
        fotPool.addLiquidity(
            address(fot) < address(plain) ? 100 ether : 100 ether,
            100 ether,
            0,
            0,
            alice
        );
        (uint256 r0, uint256 r1,) = fotPool.getReserves();
        // FoT side reserve reflects the 1%-shaved receipt.
        if (fotPool.token0() == address(fot)) {
            assertEq(r0, 99 ether);
            assertEq(r1, 100 ether);
        } else {
            assertEq(r0, 100 ether);
            assertEq(r1, 99 ether);
        }

        uint256 balBefore = fot.balanceOf(address(fotPool));
        fotPool.swapExactIn(address(fot), 10 ether, 0, alice);
        // Pool only booked what actually arrived (9.9 minus protocol accrual stays inside).
        assertEq(fot.balanceOf(address(fotPool)) - balBefore, 9.9 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzzSwapPreservesSolvency(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e3, 500_000 ether);
        _addLiquidity(alice, 1000 ether, 4000 ether);
        address tokenIn = zeroForOne ? address(token0) : address(token1);
        vm.prank(bob);
        pool.swapExactIn(tokenIn, amountIn, 0, bob);
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertGe(token0.balanceOf(address(pool)), r0 + pool.protocolFees0());
        assertGe(token1.balanceOf(address(pool)), r1 + pool.protocolFees1());
    }

    function testFuzzGetAmountOutMonotonic(uint256 a, uint256 b) public {
        _addLiquidity(alice, 1000 ether, 4000 ether);
        a = bound(a, 1e3, 100_000 ether);
        b = bound(b, a, 100_000 ether);
        assertLe(pool.getAmountOut(address(token0), a), pool.getAmountOut(address(token0), b));
    }

    function testFuzzAddRemoveRoundTripNoProfit(uint256 amt0, uint256 amt1) public {
        _addLiquidity(alice, 1000 ether, 4000 ether);
        amt0 = bound(amt0, 1 ether, 100_000 ether);
        amt1 = bound(amt1, 1 ether, 100_000 ether);
        uint256 bal0Before = token0.balanceOf(bob);
        uint256 bal1Before = token1.balanceOf(bob);
        vm.startPrank(bob);
        (uint256 liquidity,,) = pool.addLiquidity(amt0, amt1, 0, 0, bob);
        pool.removeLiquidity(liquidity, 0, 0, bob);
        vm.stopPrank();
        assertLe(token0.balanceOf(bob), bal0Before);
        assertLe(token1.balanceOf(bob), bal1Before);
    }
}
