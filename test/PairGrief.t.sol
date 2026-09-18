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

/// Regression tests for the two ways a permissionless pair used to be
/// brickable by whoever called first.
contract PairGriefTest is Test {
    DexRegistry internal registry;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

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

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (tokenA, tokenB) = address(a) < address(b) ? (a, b) : (b, a);
    }

    /// Burning every custom slot no longer takes the pair down with it: the
    /// canonical tiers remain, and a victim can build a working market on one.
    function testSquattedPairStillUsable() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));

        vm.startPrank(attacker);
        for (uint32 i = 0; i < pair.MAX_CUSTOM_SPOT_POOLS(); i++) {
            pair.createSpotPool(1 + i);
        }
        vm.expectRevert(Pair.TooManyCustomSpotPools.selector);
        pair.createSpotPool(7777);
        vm.stopPrank();

        // Victim takes a canonical tier and gets a fully working pool.
        vm.prank(victim);
        SpotPool pool = SpotPool(pair.createSpotPool(pair.FEE_TIER_MEDIUM()));

        tokenA.mint(victim, 1_000_000 ether);
        tokenB.mint(victim, 1_000_000 ether);
        vm.startPrank(victim);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        tokenA.approve(address(pair), type(uint256).max);
        pool.addLiquidity(100 ether, 400 ether, 0, 0, victim);
        pair.placeOrder(IPair.Side.SELL, 4.5e18, 10 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        (uint256 ask, uint256 total) = pair.bestAsk();
        assertEq(ask, 4.5e18);
        assertEq(total, 10 ether);
    }

    /// A squatter who grabs a canonical tier hands the victim a working pool
    /// rather than denying them one — there is nothing to deny.
    function testCanonicalTierSquatIsANoop() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        vm.prank(attacker);
        SpotPool pool = SpotPool(pair.createSpotPool(pair.FEE_TIER_MEDIUM()));

        tokenA.mint(victim, 1_000 ether);
        tokenB.mint(victim, 1_000 ether);
        vm.startPrank(victim);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        (uint256 liquidity,,) = pool.addLiquidity(100 ether, 400 ether, 0, 0, victim);
        vm.stopPrank();
        assertGt(liquidity, 0);
        assertEq(pool.lpFeeRatePpm(), pair.FEE_TIER_MEDIUM());
    }

    /// The old squat set `tickSize` to an absurd value on the first pool and
    /// froze the book forever. There is no such value to set any more.
    function testFirstPoolCreatorCannotFreezeTheBook() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        vm.prank(attacker);
        SpotPool pool = SpotPool(pair.createSpotPool(1));

        tokenA.mint(victim, 1_000 ether);
        tokenB.mint(victim, 1_000 ether);
        vm.startPrank(victim);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        tokenA.approve(address(pair), type(uint256).max);
        pool.addLiquidity(100 ether, 400 ether, 0, 0, victim);
        // Adjacent grid steps both work: at this magnitude the tick is 1e13,
        // i.e. six significant digits, roughly 0.02bp of a price near 4.5.
        assertEq(pair.tickSizeAt(4.5e18), 1e13);
        pair.placeOrder(IPair.Side.SELL, 4.5e18, 10 ether, uint64(block.timestamp + 1 days), 0);
        pair.placeOrder(IPair.Side.SELL, 4.50001e18, 10 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
        assertEq(pair.nextOrderId(), 3);
    }
}
