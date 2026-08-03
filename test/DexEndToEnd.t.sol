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

/// Full lifecycle: pair creation -> LP -> resting limit order -> market swap
/// triggers the auto-match -> perp trading against the TWAP -> liquidation.
contract DexEndToEndTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    Orderbook internal orderbook;
    SpotPool internal spot;
    PerpPool internal perp;
    MockERC20 internal base;
    MockERC20 internal quote;
    bytes32 internal pairId;

    address internal owner = makeAddr("owner");
    address internal lpUser = makeAddr("lpUser");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal degen = makeAddr("degen");

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
        vm.startPrank(owner);
        registry.setOrderbook(address(orderbook));
        registry.setFactories(
            address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry)))
        );
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (base, quote) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address[4] memory users = [lpUser, maker, taker, degen];
        for (uint256 i = 0; i < users.length; i++) {
            base.mint(users[i], 1_000_000 ether);
            quote.mint(users[i], 1_000_000 ether);
        }
    }

    function testFullLifecycle() public {
        // 1. Anyone creates a spot pool; pair + book come into existence.
        spot = SpotPool(registry.createSpotPool(address(base), address(quote), 3000, 1e15));
        pairId = spot.pairId();

        // 2. LP seeds the pool at price 4.0.
        vm.startPrank(lpUser);
        base.approve(address(spot), type(uint256).max);
        quote.approve(address(spot), type(uint256).max);
        spot.addLiquidity(10_000 ether, 40_000 ether, 0, 0, lpUser);
        vm.stopPrank();

        // 3. Maker rests a sell just above market.
        vm.startPrank(maker);
        base.approve(address(orderbook), type(uint256).max);
        uint256 orderId =
            orderbook.placeOrder(pairId, Orderbook.Side.SELL, 4.05e18, 5 ether, uint64(block.timestamp + 7 days), 0);
        vm.stopPrank();

        // 4. Taker market-buys; the price crosses 4.05 and the hook fills the
        //    resting order in the same transaction.
        vm.startPrank(taker);
        quote.approve(address(spot), type(uint256).max);
        spot.swapExactIn(address(quote), 1_000 ether, 0, taker);
        vm.stopPrank();
        (,, Orderbook.Status status,,,,,, uint256 escrow,) = orderbook.orders(orderId);
        assertEq(uint8(status), uint8(Orderbook.Status.FILLED));
        assertEq(escrow, 0);
        assertGt(quote.balanceOf(maker), 1_000_000 ether); // sold above entry holdings

        // 5. Protocol fees accrued on the spot pool; anyone sweeps them.
        assertGt(spot.protocolFees1(), 0);
        spot.collectProtocolFees();
        assertGt(quote.balanceOf(address(treasury)), 0);

        // 6. A perp pool goes live against the same pair, LP funds it.
        perp = PerpPool(
            registry.createPerpPool(
                address(base),
                address(quote),
                address(quote),
                address(spot),
                3000,
                PerpParams(10, 500, 100, 8000, 100)
            )
        );
        vm.startPrank(lpUser);
        quote.approve(address(perp), type(uint256).max);
        perp.addLiquidity(100_000 ether, 0, lpUser);
        vm.stopPrank();

        // 7. TWAP warm-up, then a degen opens a 8x long.
        perp.pokeMark();
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
        uint256 entryMark = perp.cachedMarkX18();
        assertGt(entryMark, 4e18); // price rose in step 4

        vm.startPrank(degen);
        quote.approve(address(perp), type(uint256).max);
        perp.openPosition(true, 2_100 ether, 4_000 ether);
        vm.stopPrank();

        // 8. Market dumps ~10%; mark follows after a window.
        vm.startPrank(taker);
        base.approve(address(spot), type(uint256).max);
        spot.swapExactIn(address(base), 600 ether, 0, taker);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();
        assertLt(perp.cachedMarkX18(), entryMark);

        // 9. Anyone liquidates the underwater long and pockets the reward.
        uint256 keeperBalBefore = quote.balanceOf(taker);
        vm.prank(taker);
        perp.liquidate(degen, true);
        assertGe(quote.balanceOf(taker), keeperBalBefore);
        (uint256 size,,,) = perp.positions(degen, true);
        assertEq(size, 0);

        // 10. Books stay solvent end to end.
        assertEq(
            quote.balanceOf(address(perp)), perp.totalLiquidity() + perp.protocolFeesQuote(), "perp solvency"
        );
        (uint256 r0, uint256 r1,) = spot.getReserves();
        assertGe(base.balanceOf(address(spot)), r0 + spot.protocolFees0());
        assertGe(quote.balanceOf(address(spot)), r1 + spot.protocolFees1());
        assertEq(base.balanceOf(address(orderbook)), 0);
        assertEq(quote.balanceOf(address(orderbook)), 0);
    }
}
