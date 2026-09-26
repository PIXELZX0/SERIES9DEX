// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {PriceBalancer} from "../src/PriceBalancer.sol";
import {Pausing} from "../src/libraries/Pausing.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV2Pair} from "./mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {Rebalance} from "../script/Rebalance.s.sol";

contract PriceBalancerTest is Test {
    DexRegistry internal registry;
    PriceBalancer internal balancer;
    SpotPool internal spot; // SERIES9, 0.30%, price 1.00
    MockUniswapV2Pair internal uniV2; // Uniswap V2, 0.30%, price 1.10
    MockUniswapV2Pair internal cakeV2; // PancakeSwap V2, 0.25%, price 0.95
    MockUniswapV3Pool internal cakeV3; // PancakeSwap V3, 0.25%, price 1.20
    MockERC20 internal tokenA; // token0 everywhere
    MockERC20 internal tokenB; // token1 everywhere

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant INVENTORY = 10_000 ether;
    // Two fees on the way round (0.30% + 0.30% worst case) plus rounding.
    uint256 internal constant FEE_BAND = 0.0062e18;

    function setUp() public {
        ProtocolTreasury treasury = ProtocolTreasury(
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

        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (tokenA, tokenB) = address(x) < address(y) ? (x, y) : (y, x);

        spot = SpotPool(Pair(registry.createPair(address(tokenA), address(tokenB))).createSpotPool(3000));
        tokenA.mint(lp, 100_000 ether);
        tokenB.mint(lp, 100_000 ether);
        vm.startPrank(lp);
        tokenA.approve(address(spot), type(uint256).max);
        tokenB.approve(address(spot), type(uint256).max);
        spot.addLiquidity(100_000 ether, 100_000 ether, 0, 0, lp);
        vm.stopPrank();

        uniV2 = _v2(3000, 100_000 ether, 110_000 ether);
        cakeV2 = _v2(2500, 100_000 ether, 95_000 ether);
        cakeV3 = _v3(2500, 100_000 ether, 1.2e18, true);

        balancer = new PriceBalancer(address(registry), owner, keeper);
        vm.startPrank(owner);
        balancer.setVenue(address(spot), PriceBalancer.VenueKind.Series9Spot, 0);
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.UniswapV2, 3000);
        balancer.setVenue(address(cakeV2), PriceBalancer.VenueKind.UniswapV2, 2500);
        balancer.setVenue(address(cakeV3), PriceBalancer.VenueKind.UniswapV3, 0);
        vm.stopPrank();

        tokenA.mint(address(balancer), INVENTORY);
        tokenB.mint(address(balancer), INVENTORY);
    }

    function _v2(uint256 feePpm, uint256 reserveA, uint256 reserveB) internal returns (MockUniswapV2Pair pair) {
        pair = new MockUniswapV2Pair(address(tokenA), address(tokenB), feePpm);
        tokenA.mint(address(pair), reserveA);
        tokenB.mint(address(pair), reserveB);
        pair.sync();
    }

    function _v3(uint24 fee, uint128 liquidity, uint256 priceX18, bool pancake)
        internal
        returns (MockUniswapV3Pool pool)
    {
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(priceX18, 1 << 192, 1e18)));
        pool = new MockUniswapV3Pool(address(tokenA), address(tokenB), fee, liquidity, sqrtPriceX96, pancake);
        // Enough of both sides to pay out anything a test swaps for.
        tokenA.mint(address(pool), 1_000_000 ether);
        tokenB.mint(address(pool), 1_000_000 ether);
    }

    function _spreadX18(address a, address b) internal view returns (uint256) {
        uint256 pa = balancer.priceX18(a);
        uint256 pb = balancer.priceX18(b);
        (uint256 lo, uint256 hi) = pa < pb ? (pa, pb) : (pb, pa);
        return (hi - lo) * 1e18 / lo;
    }

    // ---------------------------------------------------------------- views

    function test_priceX18_readsEveryVenueKind() public view {
        assertEq(balancer.priceX18(address(spot)), 1e18);
        assertEq(balancer.priceX18(address(uniV2)), 1.1e18);
        assertEq(balancer.priceX18(address(cakeV2)), 0.95e18);
        // Through a PancakeSwap-shaped slot0 whose feeProtocol overflows uint8.
        assertApproxEqRel(balancer.priceX18(address(cakeV3)), 1.2e18, 1e9);
    }

    function test_setVenue_readsFeeAndTokensFromPool() public view {
        PriceBalancer.Venue memory v = balancer.venue(address(cakeV3));
        assertEq(uint8(v.kind), uint8(PriceBalancer.VenueKind.UniswapV3));
        assertEq(v.feePpm, 2500);
        assertEq(v.token0, address(tokenA));
        assertEq(v.token1, address(tokenB));
        assertEq(balancer.venue(address(spot)).feePpm, 3000);
    }

    // ------------------------------------------------------------ rebalance

    function test_rebalance_spotVsV2_closesSpreadAtProfit() public {
        // A is cheaper on SERIES9 (1.00 B) than on Uniswap (1.10 B): spend B
        // buying A on SERIES9, sell it on Uniswap.
        (uint256 amountIn, uint256 expected) =
            balancer.quoteOptimalAmountIn(address(spot), address(uniV2), address(tokenB));
        assertGt(amountIn, 0);

        vm.prank(keeper);
        uint256 profit = balancer.rebalance(
            address(spot), address(uniV2), address(tokenB), amountIn, expected * 99 / 100, block.timestamp
        );

        assertApproxEqRel(profit, expected, 1e15);
        assertEq(tokenB.balanceOf(address(balancer)), INVENTORY + profit);
        assertEq(tokenA.balanceOf(address(balancer)), INVENTORY);
        assertLe(_spreadX18(address(spot), address(uniV2)), FEE_BAND);
    }

    function test_rebalance_isRepeatableUntilNothingIsLeft() public {
        _rebalanceOptimal(address(spot), address(uniV2), address(tokenB));
        (uint256 amountIn,) = balancer.quoteOptimalAmountIn(address(spot), address(uniV2), address(tokenB));
        // Whatever is left is inside the fee band and not worth taking.
        if (amountIn > 0) {
            vm.prank(keeper);
            vm.expectRevert();
            balancer.rebalance(address(spot), address(uniV2), address(tokenB), amountIn, 1e15, block.timestamp);
        }
    }

    function test_rebalance_fromToken0Inventory() public {
        // Same mispricing, the other inventory: spend A buying B on Uniswap
        // (where A is dear), buy A back on SERIES9. Profit lands in A.
        (uint256 amountIn, uint256 expected) =
            balancer.quoteOptimalAmountIn(address(uniV2), address(spot), address(tokenA));
        vm.prank(keeper);
        uint256 profit =
            balancer.rebalance(address(uniV2), address(spot), address(tokenA), amountIn, 0, block.timestamp);
        assertApproxEqRel(profit, expected, 1e15);
        assertEq(tokenA.balanceOf(address(balancer)), INVENTORY + profit);
        assertLe(_spreadX18(address(spot), address(uniV2)), FEE_BAND);
    }

    function test_rebalance_withPancakeV3() public {
        // No closed form with a V3 leg; the search finds the size.
        (uint256 amountIn, uint256 expected) =
            balancer.findOptimalAmountIn(address(spot), address(cakeV3), address(tokenB), 0, 40);
        assertGt(amountIn, 0);

        vm.prank(keeper);
        uint256 profit = balancer.rebalance(
            address(spot), address(cakeV3), address(tokenB), amountIn, expected * 99 / 100, block.timestamp
        );
        assertEq(profit, expected);
        assertLe(_spreadX18(address(spot), address(cakeV3)), FEE_BAND);
    }

    function test_rebalance_withUniswapV3Callback() public {
        MockUniswapV3Pool uniV3 = _v3(3000, 100_000 ether, 1.2e18, false);
        vm.prank(owner);
        balancer.setVenue(address(uniV3), PriceBalancer.VenueKind.UniswapV3, 0);

        (uint256 amountIn,) = balancer.findOptimalAmountIn(address(spot), address(uniV3), address(tokenB), 0, 40);
        vm.prank(keeper);
        uint256 profit =
            balancer.rebalance(address(spot), address(uniV3), address(tokenB), amountIn, 1, block.timestamp);
        assertGt(profit, 0);
        assertLe(_spreadX18(address(spot), address(uniV3)), FEE_BAND);
    }

    function test_search_agreesWithClosedForm() public {
        (uint256 exactIn, uint256 exactProfit) =
            balancer.quoteOptimalAmountIn(address(cakeV2), address(uniV2), address(tokenB));
        (uint256 foundIn, uint256 foundProfit) =
            balancer.findOptimalAmountIn(address(cakeV2), address(uniV2), address(tokenB), 0, 40);
        assertApproxEqRel(foundIn, exactIn, 0.01e18);
        assertApproxEqRel(foundProfit, exactProfit, 0.001e18);
    }

    function test_search_isCappedByInventory() public {
        (uint256 exactIn,) = balancer.quoteOptimalAmountIn(address(spot), address(uniV2), address(tokenB));
        uint256 cap = exactIn / 4;
        (uint256 foundIn, uint256 profit) =
            balancer.findOptimalAmountIn(address(spot), address(uniV2), address(tokenB), cap, 40);
        assertLe(foundIn, cap);
        assertApproxEqRel(foundIn, cap, 0.01e18);
        assertGt(profit, 0);
    }

    function test_search_returnsZeroWhenNothingToTake() public {
        (uint256 amountIn, uint256 profit) =
            balancer.findOptimalAmountIn(address(uniV2), address(spot), address(tokenB), 0, 40);
        assertEq(amountIn, 0);
        assertEq(profit, 0);
        (amountIn, profit) = balancer.quoteOptimalAmountIn(address(uniV2), address(spot), address(tokenB));
        assertEq(amountIn, 0);
        assertEq(profit, 0);
    }

    /// Keeper loop over four venues: always trade the widest pair. Every
    /// venue ends inside one fee band of every other.
    function test_keeperLoop_convergesAllVenues() public {
        address[4] memory venues = [address(spot), address(uniV2), address(cakeV2), address(cakeV3)];
        for (uint256 round = 0; round < 12; round++) {
            (address cheap, address dear) = (venues[0], venues[0]);
            for (uint256 i = 1; i < venues.length; i++) {
                if (balancer.priceX18(venues[i]) < balancer.priceX18(cheap)) cheap = venues[i];
                if (balancer.priceX18(venues[i]) > balancer.priceX18(dear)) dear = venues[i];
            }
            (uint256 amountIn,) = balancer.findOptimalAmountIn(cheap, dear, address(tokenB), 0, 40);
            if (amountIn == 0) break;
            vm.prank(keeper);
            balancer.rebalance(cheap, dear, address(tokenB), amountIn, 1, block.timestamp);
        }
        for (uint256 i = 0; i < venues.length; i++) {
            for (uint256 j = i + 1; j < venues.length; j++) {
                assertLe(_spreadX18(venues[i], venues[j]), FEE_BAND);
            }
        }
        assertGt(tokenB.balanceOf(address(balancer)), INVENTORY);
        assertEq(tokenA.balanceOf(address(balancer)), INVENTORY);
    }

    /// Whatever size the keeper picks, a rebalance either reverts or leaves
    /// the inventory strictly no smaller on both sides.
    function testFuzz_rebalance_neverLosesInventory(uint256 amountIn, uint256 skewBps, bool fromB) public {
        skewBps = bound(skewBps, 0, 5_000);
        amountIn = bound(amountIn, 1, INVENTORY);
        MockUniswapV2Pair skewed = _v2(3000, 100_000 ether, 100_000 ether * (10_000 + skewBps) / 10_000);
        vm.prank(owner);
        balancer.setVenue(address(skewed), PriceBalancer.VenueKind.UniswapV2, 3000);

        (address tokenIn, address first, address second) = fromB
            ? (address(tokenB), address(spot), address(skewed))
            : (address(tokenA), address(skewed), address(spot));
        vm.prank(keeper);
        try balancer.rebalance(first, second, tokenIn, amountIn, 0, block.timestamp) {} catch {}
        assertGe(tokenA.balanceOf(address(balancer)), INVENTORY);
        assertGe(tokenB.balanceOf(address(balancer)), INVENTORY);
    }

    // --------------------------------------------------------------- guards

    function test_rebalance_revertsWrongDirection() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PriceBalancer.NotProfitable.selector, 0, 0));
        balancer.rebalance(address(uniV2), address(spot), address(tokenB), 1_000 ether, 0, block.timestamp);
    }

    function test_rebalance_revertsBelowMinProfit() public {
        (uint256 amountIn, uint256 expected) =
            balancer.quoteOptimalAmountIn(address(spot), address(uniV2), address(tokenB));
        vm.prank(keeper);
        vm.expectPartialRevert(PriceBalancer.NotProfitable.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), amountIn, expected * 2, block.timestamp);
    }

    function test_rebalance_revertsPastDeadline() public {
        vm.warp(1000);
        vm.prank(keeper);
        vm.expectRevert(PriceBalancer.Expired.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), 1 ether, 0, 999);
    }

    function test_rebalance_revertsBeyondInventory() public {
        vm.prank(keeper);
        vm.expectRevert(PriceBalancer.InsufficientInventory.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), INVENTORY + 1, 0, block.timestamp);
    }

    function test_rebalance_onlyOperatorOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(PriceBalancer.NotOperator.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), 1 ether, 0, block.timestamp);

        vm.prank(owner);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), 100 ether, 0, block.timestamp);

        vm.prank(owner);
        balancer.setOperator(keeper, false);
        vm.prank(keeper);
        vm.expectRevert(PriceBalancer.NotOperator.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), 1 ether, 0, block.timestamp);
    }

    function test_rebalance_rejectsUnregisteredVenue() public {
        MockUniswapV2Pair rogue = _v2(3000, 100_000 ether, 200_000 ether);
        vm.prank(keeper);
        vm.expectRevert(PriceBalancer.UnknownVenue.selector);
        balancer.rebalance(address(spot), address(rogue), address(tokenB), 1 ether, 0, block.timestamp);
    }

    function test_rebalance_rejectsMismatchedPairs() public {
        MockERC20 other = new MockERC20("C", "C", 18);
        MockUniswapV2Pair pairAC = new MockUniswapV2Pair(address(tokenA), address(other), 3000);
        vm.startPrank(owner);
        balancer.setVenue(address(pairAC), PriceBalancer.VenueKind.UniswapV2, 3000);
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectRevert(PriceBalancer.PairMismatch.selector);
        balancer.rebalance(address(spot), address(pairAC), address(tokenB), 1 ether, 0, block.timestamp);
        vm.expectRevert(PriceBalancer.PairMismatch.selector);
        balancer.rebalance(address(spot), address(uniV2), address(other), 1 ether, 0, block.timestamp);
        vm.expectRevert(PriceBalancer.SameVenue.selector);
        balancer.rebalance(address(spot), address(spot), address(tokenB), 1 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_rebalance_blockedWhileSeries9Paused() public {
        vm.prank(owner);
        registry.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausing.Paused.selector);
        balancer.rebalance(address(spot), address(uniV2), address(tokenB), 100 ether, 0, block.timestamp);
    }

    function test_v2FeeSetTooLow_revertsOnPairKCheck() public {
        // A 0.30% pair registered as 0.25%: the balancer asks for too much
        // and the pair refuses, rather than anything being lost.
        MockUniswapV2Pair mislabelled = _v2(3000, 100_000 ether, 110_000 ether);
        vm.prank(owner);
        balancer.setVenue(address(mislabelled), PriceBalancer.VenueKind.UniswapV2, 2500);
        vm.prank(keeper);
        vm.expectRevert(bytes("K"));
        balancer.rebalance(address(spot), address(mislabelled), address(tokenB), 1_000 ether, 0, block.timestamp);
    }

    function test_v3Callback_rejectsUnexpectedCaller() public {
        vm.prank(address(cakeV3));
        vm.expectRevert(PriceBalancer.UnexpectedCallback.selector);
        balancer.pancakeV3SwapCallback(1 ether, 0, "");

        vm.prank(stranger);
        vm.expectRevert(PriceBalancer.UnexpectedCallback.selector);
        balancer.uniswapV3SwapCallback(1 ether, 0, "");
    }

    function test_simulateRoundTrip_onlySelf() public {
        vm.expectRevert(PriceBalancer.OnlySelf.selector);
        balancer.simulateRoundTrip(address(spot), address(uniV2), address(tokenB), 1 ether);
    }

    function test_search_leavesNoTrace() public {
        uint256 spotPrice = balancer.priceX18(address(spot));
        uint256 v3Price = balancer.priceX18(address(cakeV3));
        balancer.findOptimalAmountIn(address(spot), address(cakeV3), address(tokenB), 0, 20);
        assertEq(balancer.priceX18(address(spot)), spotPrice);
        assertEq(balancer.priceX18(address(cakeV3)), v3Price);
        assertEq(tokenB.balanceOf(address(balancer)), INVENTORY);
    }

    function test_search_rejectsTooManyIterations() public {
        uint256 limit = balancer.MAX_SEARCH_ITERATIONS();
        vm.expectRevert(PriceBalancer.TooManyIterations.selector);
        balancer.findOptimalAmountIn(address(spot), address(uniV2), address(tokenB), 0, limit + 1);
    }

    // ---------------------------------------------------------------- admin

    function test_setVenue_onlyOwner() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.UniswapV2, 3000);
    }

    function test_setVenue_series9MustBeRegistered() public {
        vm.prank(owner);
        vm.expectRevert(PriceBalancer.UnknownPool.selector);
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.Series9Spot, 0);
    }

    function test_setVenue_rejectsBadV2Fee() public {
        vm.startPrank(owner);
        vm.expectRevert(PriceBalancer.InvalidFee.selector);
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.UniswapV2, 0);
        vm.expectRevert(PriceBalancer.InvalidFee.selector);
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.UniswapV2, 1e6);
        vm.stopPrank();
    }

    function test_setVenue_noneRemoves() public {
        vm.prank(owner);
        balancer.setVenue(address(uniV2), PriceBalancer.VenueKind.None, 0);
        vm.expectRevert(PriceBalancer.UnknownVenue.selector);
        balancer.priceX18(address(uniV2));
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        balancer.withdraw(address(tokenA), keeper, 1);

        vm.prank(owner);
        balancer.withdraw(address(tokenA), owner, INVENTORY);
        assertEq(tokenA.balanceOf(owner), INVENTORY);
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        balancer.transferOwnership(stranger);
        assertEq(balancer.owner(), owner);
        vm.prank(stranger);
        balancer.acceptOwnership();
        assertEq(balancer.owner(), stranger);
    }

    // --------------------------------------------------------------- keeper

    function test_keeperScript_closesWidestSpread() public {
        (address bot, uint256 botKey) = makeAddrAndKey("bot");
        vm.prank(owner);
        balancer.setOperator(bot, true);

        vm.setEnv("BALANCER", vm.toString(address(balancer)));
        vm.setEnv(
            "VENUES",
            string.concat(
                vm.toString(address(spot)), ",", vm.toString(address(uniV2)), ",", vm.toString(address(cakeV2))
            )
        );
        vm.setEnv("TOKEN_IN", vm.toString(address(tokenB)));
        vm.setEnv("OPERATOR_PRIVATE_KEY", vm.toString(botKey));

        // Widest gap is PancakeSwap V2 (0.95) -> Uniswap V2 (1.10).
        uint256 spreadBefore = _spreadX18(address(cakeV2), address(uniV2));
        new Rebalance().run();
        assertLe(_spreadX18(address(cakeV2), address(uniV2)), FEE_BAND);
        assertLt(_spreadX18(address(cakeV2), address(uniV2)), spreadBefore);
        assertGt(tokenB.balanceOf(address(balancer)), INVENTORY);
    }

    // -------------------------------------------------------------- helpers

    function _rebalanceOptimal(address first, address second, address tokenIn) internal returns (uint256) {
        (uint256 amountIn,) = balancer.quoteOptimalAmountIn(first, second, tokenIn);
        vm.prank(keeper);
        return balancer.rebalance(first, second, tokenIn, amountIn, 0, block.timestamp);
    }
}
