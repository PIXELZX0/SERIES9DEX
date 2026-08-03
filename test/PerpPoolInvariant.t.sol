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

contract PerpHandler is Test {
    PerpPool public immutable perp;
    SpotPool public immutable spot;
    MockERC20 internal immutable base;
    MockERC20 internal immutable quote;

    constructor(PerpPool perp_, SpotPool spot_) {
        perp = perp_;
        spot = spot_;
        base = MockERC20(spot_.token0());
        quote = MockERC20(spot_.token1());
        quote.approve(address(perp_), type(uint256).max);
        base.approve(address(spot_), type(uint256).max);
        quote.approve(address(spot_), type(uint256).max);
    }

    function open(bool isLong, uint256 margin, uint256 size) external {
        margin = bound(margin, 100 ether, 5_000 ether);
        size = bound(size, 1 ether, 2_000 ether);
        quote.mint(address(this), margin);
        try perp.openPosition(isLong, margin, size) {} catch {}
    }

    function decrease(bool isLong, uint256 size) external {
        (uint256 posSize,,,) = perp.positions(address(this), isLong);
        if (posSize == 0) return;
        size = bound(size, 1, posSize);
        try perp.decreasePosition(isLong, size) {} catch {}
    }

    function margin(bool isLong, uint256 amount, bool add) external {
        amount = bound(amount, 1 ether, 1_000 ether);
        if (add) {
            quote.mint(address(this), amount);
            try perp.addMargin(isLong, amount) {} catch {}
        } else {
            try perp.removeMargin(isLong, amount) {} catch {}
        }
    }

    function lp(uint256 amount, bool add) external {
        if (add) {
            amount = bound(amount, 100 ether, 50_000 ether);
            quote.mint(address(this), amount);
            try perp.addLiquidity(amount, 0, address(this)) {} catch {}
        } else {
            uint256 shares = perp.balanceOf(address(this));
            if (shares == 0) return;
            amount = bound(amount, 1, shares);
            try perp.removeLiquidity(amount, 0, address(this)) {} catch {}
        }
    }

    function movePriceAndWarp(uint256 amountIn, bool up, uint256 dt) external {
        amountIn = bound(amountIn, 1 ether, 500 ether);
        dt = bound(dt, 1, 2 hours);
        MockERC20 tokenIn = up ? quote : base;
        tokenIn.mint(address(this), amountIn);
        try spot.swapExactIn(address(tokenIn), amountIn, 0, address(this)) {} catch {}
        vm.warp(block.timestamp + dt);
        perp.pokeMark();
        perp.updateFunding();
    }

    function tryLiquidate(bool isLong) external {
        try perp.liquidate(address(this), isLong) {} catch {}
    }
}

contract PerpPoolInvariantTest is Test {
    PerpPool internal perp;
    PerpHandler internal handler;
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
        vm.startPrank(owner);
        registry.setOrderbook(address(new Orderbook(address(registry))));
        registry.setFactories(
            address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry)))
        );
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        SpotPool spot;
        {
            spot = SpotPool(registry.createSpotPool(address(tokenA), address(tokenB), 3000, 1e15));
        }
        MockERC20 base = MockERC20(spot.token0());
        quote = MockERC20(spot.token1());
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

        base.mint(address(this), 10_000 ether);
        quote.mint(address(this), 140_000 ether);
        base.approve(address(spot), type(uint256).max);
        quote.approve(address(spot), type(uint256).max);
        quote.approve(address(perp), type(uint256).max);
        spot.addLiquidity(10_000 ether, 40_000 ether, 0, 0, address(this));
        perp.addLiquidity(100_000 ether, 0, address(this));

        // Warm the TWAP so the handler can trade immediately.
        perp.pokeMark();
        vm.warp(vm.getBlockTimestamp() + 301);
        perp.pokeMark();

        handler = new PerpHandler(perp, spot);
        targetContract(address(handler));
    }

    /// Realized accounting always covers the books: balance == vault + margins + protocol fees.
    function invariant_accountingSolvent() public view {
        (, uint256 mLong,,) = perp.positions(address(handler), true);
        (, uint256 mShort,,) = perp.positions(address(handler), false);
        assertEq(
            quote.balanceOf(address(perp)),
            perp.totalLiquidity() + mLong + mShort + perp.protocolFeesQuote()
        );
    }

    /// Open notional ledgers match the single handler's positions.
    function invariant_openInterestConsistent() public view {
        (uint256 sLong,, uint256 nLong,) = perp.positions(address(handler), true);
        (uint256 sShort,, uint256 nShort,) = perp.positions(address(handler), false);
        assertEq(perp.longSizeBase(), sLong);
        assertEq(perp.shortSizeBase(), sShort);
        assertEq(perp.longOpenNotional(), nLong);
        assertEq(perp.shortOpenNotional(), nShort);
    }
}
