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
import {Pair} from "../src/Pair.sol";
import {PerpParams, LpStatus} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Drives requests, executions, cancellations, liquidations and price moves
/// in any order and at any time. Execution happens whenever the fuzzer gets
/// to it — often late — which is exactly the case the late-execution rule
/// has to keep honest.
contract PerpHandler is Test {
    PerpPool public immutable perp;
    SpotPool public immutable spot;
    MockERC20 internal immutable base;
    MockERC20 internal immutable quote;
    uint256[] public lpRequestIds;
    uint256 public executed; // orders that took effect
    uint256 public lpExecuted;

    constructor(PerpPool perp_, SpotPool spot_) {
        perp = perp_;
        spot = spot_;
        base = MockERC20(spot_.token0());
        quote = MockERC20(spot_.token1());
        quote.approve(address(perp_), type(uint256).max);
        base.approve(address(spot_), type(uint256).max);
        quote.approve(address(spot_), type(uint256).max);
    }

    function requestOpen(bool isLong, uint256 marginIn, uint256 size) external {
        marginIn = bound(marginIn, 100 ether, 5_000 ether);
        size = bound(size, 1 ether, 2_000 ether);
        quote.mint(address(this), marginIn + 1 ether);
        try perp.requestIncrease(isLong, marginIn, size, 0, 1 ether) {} catch {}
    }

    function requestDecrease(bool isLong, uint256 size) external {
        size = bound(size, 1, 3_000 ether);
        try perp.requestDecrease(isLong, size, 0, 0) {} catch {}
    }

    function requestRemoveMargin(bool isLong, uint256 amount) external {
        amount = bound(amount, 1 ether, 1_000 ether);
        try perp.requestRemoveMargin(isLong, amount, 0) {} catch {}
    }

    function addMargin(bool isLong, uint256 amount) external {
        amount = bound(amount, 1 ether, 1_000 ether);
        quote.mint(address(this), amount);
        try perp.addMargin(isLong, amount) {} catch {}
    }

    /// Usually what a keeper does — execute in the settlement epoch — and
    /// otherwise whenever the fuzzer gets here.
    function execute(bool isLong, bool prompt) external {
        (, uint64 settleAt,,,,,,,) = perp.orders(address(this), isLong);
        if (prompt && settleAt > block.timestamp) vm.warp(settleAt);
        uint256[3] memory h;
        try perp.executeOrder(address(this), isLong, h) returns (bool ok) {
            if (ok) executed++;
        } catch {}
    }

    function lp(uint256 amount, bool add) external {
        uint256 id;
        if (add) {
            amount = bound(amount, 2_000 ether, 50_000 ether);
            quote.mint(address(this), amount);
            try perp.requestDeposit(amount, 0, address(this), address(this), 0) returns (uint256 r) {
                id = r;
            } catch {}
        } else {
            uint256 shares = perp.sharesOf(address(this));
            if (shares == 0) return;
            amount = bound(amount, 1, shares);
            try perp.requestWithdraw(amount, 0, address(this), address(this), 0) returns (uint256 r) {
                id = r;
            } catch {}
        }
        if (id != 0) lpRequestIds.push(id);
    }

    function executeLp(uint256 index, bool prompt) external {
        if (lpRequestIds.length == 0) return;
        uint256 id = lpRequestIds[bound(index, 0, lpRequestIds.length - 1)];
        (,,,,, uint64 settleAt,,,,,,) = perp.lpRequests(id);
        if (prompt && settleAt > block.timestamp) vm.warp(settleAt);
        uint256[3] memory h;
        try perp.executeLp(id, h) {
            lpExecuted++;
        } catch {}
    }

    function movePriceAndWarp(uint256 amountIn, bool up, uint256 dt) external {
        amountIn = bound(amountIn, 1 ether, 5_000 ether);
        dt = bound(dt, 1, 30 minutes);
        MockERC20 tokenIn = up ? quote : base;
        tokenIn.mint(address(this), amountIn);
        try spot.swapExactIn(address(tokenIn), amountIn, 0, address(this)) {} catch {}
        vm.warp(block.timestamp + dt);
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
        vm.warp(1_700_000_000);
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
        registry.setFactories(
            address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry)))
        );
        vm.stopPrank();

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB)));
        SpotPool spot;
        {
            spot = SpotPool(pair.createSpotPool(3000));
        }
        MockERC20 base = MockERC20(spot.token0());
        quote = MockERC20(spot.token1());
        perp = PerpPool(pair.createPerpPool(address(quote), address(spot), 3000, PerpParams(10, 500, 100, 8000, 100)));

        base.mint(address(this), 100_000 ether);
        quote.mint(address(this), 500_000 ether);
        base.approve(address(spot), type(uint256).max);
        quote.approve(address(spot), type(uint256).max);
        quote.approve(address(perp), type(uint256).max);
        spot.addLiquidity(100_000 ether, 400_000 ether, 0, 0, address(this));
        vm.warp(block.timestamp + perp.DEPTH_WINDOW()); // positions need an hour of oracle history

        uint256 id = perp.requestDeposit(100_000 ether, 0, address(this), address(this), 0);
        (,,,,, uint64 settleAt,,,,,,) = perp.lpRequests(id);
        vm.warp(settleAt);
        uint256[3] memory h;
        perp.executeLp(id, h);

        handler = new PerpHandler(perp, spot);
        targetContract(address(handler));
    }

    /// Realized accounting always covers the books:
    /// balance == vault + margins + protocol fees + escrow.
    function invariant_accountingSolvent() public view {
        (, uint256 mLong,,) = perp.positions(address(handler), true);
        (, uint256 mShort,,) = perp.positions(address(handler), false);
        assertEq(
            quote.balanceOf(address(perp)),
            perp.totalLiquidity() + mLong + mShort + perp.protocolFeesQuote() + perp.escrowedQuote()
        );
    }

    /// Open interest ledgers match the single handler's positions.
    function invariant_openInterestConsistent() public view {
        (uint256 sLong,, uint256 nLong,) = perp.positions(address(handler), true);
        (uint256 sShort,, uint256 nShort,) = perp.positions(address(handler), false);
        assertEq(perp.longSizeBase(), sLong);
        assertEq(perp.shortSizeBase(), sShort);
        assertEq(perp.longOpenNotional(), nLong);
        assertEq(perp.shortOpenNotional(), nShort);
    }

    /// Admitted interest is held exactly while its request is pending.
    function invariant_pendingInterestMatchesOrders() public view {
        (PerpPool.OrderKind kLong,,,,,, uint256 rLong,,) = perp.orders(address(handler), true);
        (PerpPool.OrderKind kShort,,,,,, uint256 rShort,,) = perp.orders(address(handler), false);
        assertEq(perp.pendingLongNotional(), kLong == PerpPool.OrderKind.INCREASE ? rLong : 0);
        assertEq(perp.pendingShortNotional(), kShort == PerpPool.OrderKind.INCREASE ? rShort : 0);
    }

    /// Every share is held by someone or escrowed by a pending withdrawal.
    function invariant_sharesAccountedFor() public view {
        assertEq(
            perp.totalShares(),
            perp.sharesOf(address(handler)) + perp.sharesOf(address(this)) + perp.sharesOf(address(0xdead))
                + perp.escrowedShares()
        );
    }

    /// The funding-entry sums stay exactly the sum over positions.
    function invariant_fundingEntryConsistent() public view {
        (uint256 sLong,,, uint256 eLong) = perp.positions(address(handler), true);
        (uint256 sShort,,, uint256 eShort) = perp.positions(address(handler), false);
        assertEq(perp.longFundingEntry(), sLong * eLong / 1e36);
        assertEq(perp.shortFundingEntry(), sShort * eShort / 1e36);
    }
}
