// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {Pair} from "../src/Pair.sol";
import {DexRouter} from "../src/DexRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexRouterTest is Test {
    DexRegistry internal registry;
    DexRouter internal router;
    SpotPool internal poolAB;
    SpotPool internal poolBC;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal user = makeAddr("user");

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
        router = new DexRouter(address(registry));

        // Three tokens with a deterministic A < B < C ordering so the pair
        // sorting below is predictable.
        MockERC20[3] memory made =
            [new MockERC20("A", "A", 18), new MockERC20("B", "B", 18), new MockERC20("C", "C", 18)];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(made[j]) < address(made[i])) (made[i], made[j]) = (made[j], made[i]);
            }
        }
        (tokenA, tokenB, tokenC) = (made[0], made[1], made[2]);

        poolAB = SpotPool(Pair(registry.createPair(address(tokenA), address(tokenB))).createSpotPool(3000));
        poolBC = SpotPool(Pair(registry.createPair(address(tokenB), address(tokenC))).createSpotPool(3000));

        address[2] memory users = [lp, user];
        for (uint256 i = 0; i < users.length; i++) {
            tokenA.mint(users[i], 1_000_000 ether);
            tokenB.mint(users[i], 1_000_000 ether);
            tokenC.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            tokenA.approve(address(poolAB), type(uint256).max);
            tokenB.approve(address(poolAB), type(uint256).max);
            tokenB.approve(address(poolBC), type(uint256).max);
            tokenC.approve(address(poolBC), type(uint256).max);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            tokenC.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        vm.startPrank(lp);
        poolAB.addLiquidity(100_000 ether, 100_000 ether, 0, 0, lp);
        poolBC.addLiquidity(100_000 ether, 100_000 ether, 0, 0, lp);
        vm.stopPrank();
    }

    function _path2() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(poolAB);
        p[1] = address(poolBC);
    }

    function _path1() internal view returns (address[] memory p) {
        p = new address[](1);
        p[0] = address(poolAB);
    }

    function testSingleHopMatchesPoolQuote() public {
        uint256 expected = router.quoteExactInput(_path1(), address(tokenA), 100 ether);
        uint256 before = tokenB.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swapExactTokensForTokens(
            _path1(), address(tokenA), 100 ether, expected, user, block.timestamp + 1
        );
        assertEq(out, expected);
        assertEq(tokenB.balanceOf(user) - before, expected);
    }

    function testMultiHopEndsAtLastToken() public {
        uint256 expected = router.quoteExactInput(_path2(), address(tokenA), 100 ether);
        uint256 beforeC = tokenC.balanceOf(user);
        vm.prank(user);
        uint256 out =
            router.swapExactTokensForTokens(_path2(), address(tokenA), 100 ether, 0, user, block.timestamp + 1);
        assertEq(out, expected);
        assertEq(tokenC.balanceOf(user) - beforeC, out);
        // Router keeps nothing.
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
        assertEq(tokenC.balanceOf(address(router)), 0);
    }

    function testQuoteExactOutputRoundTrips() public view {
        uint256 targetOut = 50 ether;
        uint256 needed = router.quoteExactOutput(_path2(), address(tokenA), targetOut);
        // Rounding is upward at every step, so the quoted input must deliver
        // at least the target.
        assertGe(router.quoteExactInput(_path2(), address(tokenA), needed), targetOut);
    }

    function testDeadlineEnforced() public {
        vm.warp(1000);
        vm.prank(user);
        vm.expectRevert(DexRouter.Expired.selector);
        router.swapExactTokensForTokens(_path1(), address(tokenA), 1 ether, 0, user, 999);
    }

    function testSlippageEnforced() public {
        uint256 expected = router.quoteExactInput(_path1(), address(tokenA), 100 ether);
        vm.prank(user);
        vm.expectRevert(DexRouter.InsufficientOutput.selector);
        router.swapExactTokensForTokens(
            _path1(), address(tokenA), 100 ether, expected + 1, user, block.timestamp + 1
        );
    }

    /// A hop pointed at a contract the registry never issued must not get the
    /// caller's allowance approved to it.
    function testUnknownPoolRejected() public {
        address[] memory path = new address[](1);
        path[0] = address(0xdead);
        vm.prank(user);
        vm.expectRevert(DexRouter.UnknownPool.selector);
        router.swapExactTokensForTokens(path, address(tokenA), 1 ether, 0, user, block.timestamp + 1);
    }

    function testEmptyPathRejected() public {
        vm.prank(user);
        vm.expectRevert(DexRouter.EmptyPath.selector);
        router.swapExactTokensForTokens(new address[](0), address(tokenA), 1 ether, 0, user, block.timestamp + 1);
    }

    function testGetAmountInInvertsGetAmountOut() public view {
        uint256 amountIn = 1234 ether;
        uint256 out = poolAB.getAmountOut(address(tokenA), amountIn);
        uint256 backIn = poolAB.getAmountIn(address(tokenA), out);
        // Ceil rounding means backIn lands at or just above the original.
        assertGe(backIn, amountIn - 1);
        assertLe(backIn, amountIn + 2);
    }
}
