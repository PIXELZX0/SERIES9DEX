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
import {Orderbook} from "../src/Orderbook.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PerpPoolTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    SpotPool internal spot;
    PerpPool internal perp;
    MockERC20 internal base; // token0
    MockERC20 internal quote; // token1

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    uint32 internal constant FEE_PPM = 3000;

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
        Orderbook orderbook = new Orderbook(address(registry));
        vm.startPrank(owner);
        registry.setOrderbook(address(orderbook));
        registry.setFactories(address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry))));
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (base, quote) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        spot = SpotPool(registry.createSpotPool(address(base), address(quote), FEE_PPM, 1e15));
        perp = PerpPool(
            registry.createPerpPool(
                address(base),
                address(quote),
                address(quote),
                address(spot),
                FEE_PPM,
                PerpParams({
                    maxLeverageX: 10,
                    maintenanceMarginBps: 500,
                    liquidationFeeBps: 100,
                    maxUtilizationBps: 8000,
                    fundingCoeffPpmPerHour: 100
                })
            )
        );

        address[4] memory users = [lp, trader, keeper, owner];
        for (uint256 i = 0; i < users.length; i++) {
            base.mint(users[i], 10_000_000 ether);
            quote.mint(users[i], 10_000_000 ether);
            vm.startPrank(users[i]);
            base.approve(address(spot), type(uint256).max);
            quote.approve(address(spot), type(uint256).max);
            quote.approve(address(perp), type(uint256).max);
            vm.stopPrank();
        }

        // Spot at price 4.0 (quote per base), deep enough for TWAP sanity.
        vm.prank(lp);
        spot.addLiquidity(10_000 ether, 40_000 ether, 0, 0, lp);
        // LP vault.
        vm.prank(lp);
        perp.addLiquidity(100_000 ether, 0, lp);
    }

    /// Warm the TWAP so cachedMark ~= current spot price.
    function _warmMark() internal {
        perp.pokeMark();
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
    }

    /// Move the spot price and roll the mark onto it.
    function _movePriceAndRoll(bool up, uint256 amountIn) internal {
        vm.prank(keeper);
        spot.swapExactIn(up ? address(quote) : address(base), amountIn, 0, keeper);
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
    }

    function _pos(address who, bool isLong)
        internal
        view
        returns (uint256 size, uint256 margin, uint256 entryNotional)
    {
        (size, margin, entryNotional,) = perp.positions(who, isLong);
    }

    function _invariantHolds() internal view {
        uint256 sumMargins;
        (, uint256 m1,) = _pos(trader, true);
        (, uint256 m2,) = _pos(trader, false);
        (, uint256 m3,) = _pos(keeper, true);
        (, uint256 m4,) = _pos(keeper, false);
        sumMargins = m1 + m2 + m3 + m4;
        assertEq(
            quote.balanceOf(address(perp)),
            perp.totalLiquidity() + sumMargins + perp.protocolFeesQuote(),
            "accounting invariant"
        );
    }

    // -------------------------------------------------------------- oracle

    function testMarkNotReadyBeforeWarmup() public {
        vm.prank(trader);
        vm.expectRevert(PerpPool.MarkNotReady.selector);
        perp.openPosition(true, 100 ether, 10 ether);
    }

    function testMarkTracksTwap() public {
        _warmMark();
        assertApproxEqRel(perp.cachedMarkX18(), 4e18, 1e15);
        // Window not elapsed => mark frozen.
        vm.prank(keeper);
        spot.swapExactIn(address(quote), 5000 ether, 0, keeper);
        perp.pokeMark();
        assertApproxEqRel(perp.cachedMarkX18(), 4e18, 1e15);
        // After a full window the mark rolls to the new price.
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
        assertGt(perp.cachedMarkX18(), 4.5e18);
    }

    // ------------------------------------------------------------------ LP

    function testLpSharesPriceAgainstEquity() public {
        _warmMark();
        assertEq(perp.balanceOf(lp), 100_000 ether); // 1:1 initial
        vm.prank(keeper);
        uint256 shares = perp.addLiquidity(50_000 ether, 0, keeper);
        assertEq(shares, 50_000 ether); // no PnL => still 1:1
        vm.prank(keeper);
        uint256 out = perp.removeLiquidity(shares, 0, keeper);
        assertEq(out, 50_000 ether);
        _invariantHolds();
    }

    function testRemoveLiquidityUtilizationGuard() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 15_000 ether); // notional 60k vs equity ~100k
        vm.startPrank(lp);
        vm.expectRevert(PerpPool.UtilizationExceeded.selector);
        perp.removeLiquidity(90_000 ether, 0, lp);
        vm.stopPrank();
    }

    // ----------------------------------------------------------- positions

    function testOpenLongChargesFeeAndChecksLeverage() public {
        _warmMark();
        uint256 mark = perp.cachedMarkX18();
        vm.prank(trader);
        perp.openPosition(true, 1000 ether, 1000 ether); // notional ~4000
        (uint256 size, uint256 margin, uint256 entryNotional) = _pos(trader, true);
        assertEq(size, 1000 ether);
        uint256 notional = 1000 ether * mark / 1e18;
        uint256 fee = notional * FEE_PPM / 1e6;
        assertEq(margin, 1000 ether - fee);
        assertEq(entryNotional, notional);
        assertEq(perp.longSizeBase(), 1000 ether);
        assertGt(perp.protocolFeesQuote(), 0);
        _invariantHolds();

        // 11x leverage rejected (max 10x).
        vm.prank(keeper);
        vm.expectRevert(PerpPool.LeverageTooHigh.selector);
        perp.openPosition(true, 1000 ether, 2800 ether); // ~11200 notional
    }

    function testOpenPositionUtilizationCap() public {
        _warmMark();
        // Side cap = 80% of ~100k equity = 80k notional => 20k base at price 4.
        vm.prank(trader);
        vm.expectRevert(PerpPool.UtilizationExceeded.selector);
        perp.openPosition(true, 30_000 ether, 25_000 ether); // 100k notional
    }

    function testLongProfitPaidFromVault() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 5_000 ether); // entry ~4.0, notional 20k
        uint256 tlBefore = perp.totalLiquidity();

        _movePriceAndRoll(true, 5_000 ether); // price up
        uint256 mark = perp.cachedMarkX18();
        assertGt(mark, 4e18);

        uint256 balBefore = quote.balanceOf(trader);
        vm.prank(trader);
        perp.decreasePosition(true, 5_000 ether);
        uint256 payout = quote.balanceOf(trader) - balBefore;

        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        assertEq(perp.longSizeBase(), 0);
        // Trader made money; vault paid for it.
        assertGt(payout, 10_000 ether - 200 ether); // margin minus fees, plus profit
        assertLt(perp.totalLiquidity(), tlBefore + 100 ether);
        _invariantHolds();
    }

    function testShortProfitOnPriceDrop() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(false, 10_000 ether, 5_000 ether);
        _movePriceAndRoll(false, 2_000 ether); // dump base => price down
        uint256 balBefore = quote.balanceOf(trader);
        vm.prank(trader);
        perp.decreasePosition(false, 5_000 ether);
        uint256 payout = quote.balanceOf(trader) - balBefore;
        assertGt(payout, 10_000 ether); // profit beyond margin despite fees
        _invariantHolds();
    }

    function testPartialDecreaseKeepsProportions() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 4_000 ether);
        (uint256 sizeBefore, uint256 marginBefore, uint256 notionalBefore) = _pos(trader, true);
        vm.prank(trader);
        perp.decreasePosition(true, 1_000 ether);
        (uint256 size, uint256 margin, uint256 entryNotional) = _pos(trader, true);
        assertEq(size, sizeBefore - 1_000 ether);
        assertEq(entryNotional, notionalBefore - notionalBefore / 4);
        assertEq(margin, marginBefore - marginBefore / 4);
        _invariantHolds();
    }

    // -------------------------------------------------------------- funding

    function testFundingAccruesFromHeavySideToVault() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 5_000 ether); // all-long book
        uint256 tlBefore = perp.totalLiquidity();
        (, uint256 marginBefore,) = _pos(trader, true);

        vm.warp(block.timestamp + 10 hours);
        perp.pokeMark();
        perp.updateFunding();
        assertGt(perp.cumFundingLongX18(), 0);
        assertEq(perp.cumFundingShortX18(), 0);

        // Touch the position to settle: margin down, vault up.
        vm.prank(trader);
        perp.addMargin(true, 1);
        (, uint256 marginAfter,) = _pos(trader, true);
        // 100% imbalance @100ppm/h for 10h on 20k notional ~= 20 quote.
        uint256 paid = marginBefore + 1 - marginAfter;
        assertApproxEqRel(paid, 20 ether, 5e16);
        assertApproxEqRel(perp.totalLiquidity() - tlBefore, paid, 1e15);
        _invariantHolds();
    }

    function testBalancedBookNoFunding() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 5_000 ether);
        vm.prank(keeper);
        perp.openPosition(false, 10_000 ether, 5_000 ether);
        vm.warp(block.timestamp + 10 hours);
        perp.updateFunding();
        assertEq(perp.cumFundingLongX18(), 0);
        assertEq(perp.cumFundingShortX18(), 0);
    }

    // ----------------------------------------------------------- liquidation

    function testLiquidationFlow() public {
        _warmMark();
        // ~8x long: entry 4.0, notional 16k, margin 2k (fee shaves a bit).
        vm.prank(trader);
        perp.openPosition(true, 2_048 ether, 4_000 ether);

        vm.prank(keeper);
        vm.expectRevert(PerpPool.NotLiquidatable.selector);
        perp.liquidate(trader, true);

        // Price drop ~10% => loss ~1.6k, equity ~0.4k < 5% maintenance (~0.7k)
        // on ~14.4k notional, but still positive so a reward remains.
        _movePriceAndRoll(false, 550 ether);
        uint256 tlBefore = perp.totalLiquidity();
        uint256 keeperBalBefore = quote.balanceOf(keeper);
        vm.prank(keeper);
        perp.liquidate(trader, true);

        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        assertEq(perp.longSizeBase(), 0);
        uint256 reward = quote.balanceOf(keeper) - keeperBalBefore;
        assertGt(reward, 0);
        assertGt(perp.totalLiquidity(), tlBefore); // forfeited margin -> vault
        _invariantHolds();
    }

    function testBadDebtAbsorbedByVault() public {
        _warmMark();
        // 10x long, then a >10% drop: equity deeply negative.
        vm.prank(trader);
        perp.openPosition(true, 1_030 ether, 2_500 ether); // ~9.8x
        _movePriceAndRoll(false, 3_000 ether); // massive dump
        vm.prank(keeper);
        perp.liquidate(trader, true);
        (uint256 size,,) = _pos(trader, true);
        assertEq(size, 0);
        _invariantHolds(); // vault ate the loss, books still balance
    }

    // ---------------------------------------------------------------- misc

    function testRemoveMarginGuards() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 10_000 ether, 5_000 ether); // 2x
        vm.startPrank(trader);
        vm.expectRevert(PerpPool.LeverageTooHigh.selector);
        perp.removeMargin(true, 8_500 ether); // would exceed 10x
        perp.removeMargin(true, 5_000 ether); // fine at ~4x
        vm.stopPrank();
        _invariantHolds();
    }

    function testCollectProtocolFees() public {
        _warmMark();
        vm.prank(trader);
        perp.openPosition(true, 1_000 ether, 1_000 ether);
        uint256 fee = perp.protocolFeesQuote();
        assertGt(fee, 0);
        perp.collectProtocolFees();
        assertEq(quote.balanceOf(address(treasury)), fee);
        assertEq(perp.protocolFeesQuote(), 0);
        _invariantHolds();
    }

    function testCreatePerpPoolValidation() public {
        vm.expectRevert(DexRegistry.InvalidQuoteToken.selector);
        registry.createPerpPool(
            address(base),
            address(quote),
            address(0xbeef),
            address(spot),
            FEE_PPM,
            PerpParams(10, 500, 100, 8000, 100)
        );
        vm.expectRevert(DexRegistry.UnknownSpotPool.selector);
        registry.createPerpPool(
            address(base), address(quote), address(quote), address(0xbeef), FEE_PPM, PerpParams(10, 500, 100, 8000, 100)
        );
        vm.expectRevert(DexRegistry.InvalidPerpParams.selector);
        registry.createPerpPool(
            address(base), address(quote), address(quote), address(spot), FEE_PPM, PerpParams(51, 500, 100, 8000, 100)
        );
    }
}
