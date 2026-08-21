// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderbook} from "./mocks/MockOrderbook.sol";

contract SpotPoolHandler is Test {
    SpotPool public immutable pool;
    MockERC20 internal immutable token0;
    MockERC20 internal immutable token1;
    uint256 public lastK;

    constructor(SpotPool pool_) {
        pool = pool_;
        token0 = MockERC20(pool_.token0());
        token1 = MockERC20(pool_.token1());
        token0.approve(address(pool_), type(uint256).max);
        token1.approve(address(pool_), type(uint256).max);
    }

    function _k() internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        return r0 * r1;
    }

    function swap(uint256 amountIn, bool zeroForOne) external {
        amountIn = bound(amountIn, 1e3, 100_000 ether);
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        tokenIn.mint(address(this), amountIn);
        uint256 kBefore = _k();
        pool.swapExactIn(address(tokenIn), amountIn, 0, address(this));
        // k must never decrease on a swap (fees stay in reserves).
        assertGe(_k(), kBefore);
        lastK = _k();
    }

    function addLiquidity(uint256 amt0, uint256 amt1) external {
        amt0 = bound(amt0, 1e3, 100_000 ether);
        amt1 = bound(amt1, 1e3, 100_000 ether);
        token0.mint(address(this), amt0);
        token1.mint(address(this), amt1);
        try pool.addLiquidity(amt0, amt1, 0, 0, address(this)) {} catch {}
        lastK = _k();
    }

    function removeLiquidity(uint256 liquidity) external {
        uint256 bal = pool.sharesOf(address(this));
        if (bal == 0) return;
        liquidity = bound(liquidity, 1, bal);
        try pool.removeLiquidity(liquidity, 0, 0, address(this)) {} catch {}
        lastK = _k();
    }

    function collectFees() external {
        pool.collectProtocolFees();
    }
}

contract SpotPoolInvariantTest is Test {
    SpotPool internal pool;
    SpotPoolHandler internal handler;
    MockERC20 internal token0;
    MockERC20 internal token1;

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
        registry.setOrderbook(address(new MockOrderbook()));
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        pool = SpotPool(registry.createSpotPool(address(tokenA), address(tokenB), 3000, 1e15));
        token0 = MockERC20(pool.token0());
        token1 = MockERC20(pool.token1());

        handler = new SpotPoolHandler(pool);
        // Seed initial liquidity so swaps are always possible.
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1000 ether, 1000 ether, 0, 0, address(this));

        targetContract(address(handler));
    }

    /// Pool token balances always cover booked reserves + accrued protocol fees.
    function invariant_solvency() public view {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertGe(token0.balanceOf(address(pool)), r0 + pool.protocolFees0());
        assertGe(token1.balanceOf(address(pool)), r1 + pool.protocolFees1());
    }

    /// LP supply and reserves are zero/non-zero together.
    function invariant_reservesBackSupply() public view {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        if (pool.totalShares() > 0) {
            assertGt(r0, 0);
            assertGt(r1, 0);
        }
    }
}
