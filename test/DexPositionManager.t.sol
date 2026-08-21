// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {DexPositionManager} from "../src/DexPositionManager.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PerpPool} from "../src/PerpPool.sol";
import {PerpPoolFactory} from "../src/PerpPoolFactory.sol";
import {Orderbook} from "../src/Orderbook.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexPositionManagerTest is Test {
    DexRegistry internal registry;
    DexPositionManager internal manager;
    SpotPool internal spot;
    PerpPool internal perp;
    MockERC20 internal base; // token0
    MockERC20 internal quote; // token1
    PositionManagerHarness internal harness;
    HostileSymbolERC20 internal hostile;
    RevertingSymbolERC20 internal noSymbol;
    EmptySymbolERC20 internal emptySymbol;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint32 internal constant FEE_PPM = 3000;

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
        vm.startPrank(owner);
        registry.setOrderbook(address(new Orderbook(address(registry))));
        registry.setFactories(
            address(new SpotPoolFactory(address(registry))), address(new PerpPoolFactory(address(registry)))
        );
        vm.stopPrank();

        manager = new DexPositionManager(address(registry));
        harness = new PositionManagerHarness(address(registry));
        hostile = new HostileSymbolERC20();
        noSymbol = new RevertingSymbolERC20();
        emptySymbol = new EmptySymbolERC20();

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

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            base.mint(users[i], 1_000_000 ether);
            quote.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            base.approve(address(manager), type(uint256).max);
            quote.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ spot

    function test_mintSpot_mintsNftBackedByPoolShares() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 liquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        assertEq(tokenId, 1);
        assertEq(manager.ownerOf(tokenId), alice);
        (address pool, bool isSpot, uint256 recorded) = manager.positions(tokenId);
        assertEq(pool, address(spot));
        assertTrue(isSpot);
        assertEq(recorded, liquidity);
        // Shares are custodied by the manager, not the NFT holder.
        assertEq(spot.sharesOf(address(manager)), liquidity);
        assertEq(spot.sharesOf(alice), 0);
    }

    function test_mintSpot_refundsUnusedToken() public {
        vm.prank(alice);
        manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        // Second mint at a 1:1 ratio: the pool takes only the ratio-optimal
        // amount, the rest must come back rather than sit in the manager.
        uint256 balanceBefore = quote.balanceOf(bob);
        vm.prank(bob);
        manager.mintSpot(address(spot), 100 ether, 4000 ether, 0, 0, bob);

        assertEq(quote.balanceOf(bob), balanceBefore - 400 ether);
        assertEq(base.balanceOf(address(manager)), 0);
        assertEq(quote.balanceOf(address(manager)), 0);
    }

    function test_transferNft_transfersWithdrawalRight() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 liquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        vm.prank(alice);
        manager.transferFrom(alice, bob, tokenId);

        // Old owner can no longer withdraw.
        vm.prank(alice);
        vm.expectRevert(DexPositionManager.NotAuthorized.selector);
        manager.decreaseSpot(tokenId, liquidity, 0, 0, alice);

        uint256 baseBefore = base.balanceOf(bob);
        vm.prank(bob);
        (uint256 amount0,) = manager.decreaseSpot(tokenId, liquidity, 0, 0, bob);
        assertGt(amount0, 0);
        assertEq(base.balanceOf(bob), baseBefore + amount0);
    }

    function test_increaseSpot_thenDecreasePartially() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 liquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        vm.prank(alice);
        uint256 added = manager.increaseSpot(tokenId, 1000 ether, 4000 ether, 0, 0);
        (,, uint256 recorded) = manager.positions(tokenId);
        assertEq(recorded, liquidity + added);

        vm.prank(alice);
        manager.decreaseSpot(tokenId, added, 0, 0, alice);
        (,, recorded) = manager.positions(tokenId);
        assertEq(recorded, liquidity);
        assertEq(spot.sharesOf(address(manager)), liquidity);
    }

    function test_decreaseSpot_revertsAboveRecordedLiquidity() public {
        vm.prank(alice);
        (uint256 aliceId, uint256 aliceLiquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);
        vm.prank(bob);
        manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, bob);

        // Bob's shares sit in the same manager; Alice must not reach them.
        vm.prank(alice);
        vm.expectRevert(DexPositionManager.InsufficientPositionLiquidity.selector);
        manager.decreaseSpot(aliceId, aliceLiquidity + 1, 0, 0, alice);
    }

    function test_spotPositionAccruesFeesWithoutCollect() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 liquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        vm.startPrank(bob);
        base.approve(address(spot), type(uint256).max);
        quote.approve(address(spot), type(uint256).max);
        spot.swapExactIn(address(base), 100 ether, 0, bob);
        spot.swapExactIn(address(quote), 400 ether, 0, bob);
        vm.stopPrank();

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = manager.decreaseSpot(tokenId, liquidity, 0, 0, alice);
        // Fees compounded into reserves, so the same shares redeem for more.
        assertGt(amount0 + amount1 / 4, 1000 ether + 4000 ether / 4);
    }

    // ------------------------------------------------------------------ perp

    function test_mintPerp_andDecrease() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 shares) = manager.mintPerp(address(perp), 100_000 ether, 0, alice);

        assertEq(manager.ownerOf(tokenId), alice);
        (address pool, bool isSpot, uint256 recorded) = manager.positions(tokenId);
        assertEq(pool, address(perp));
        assertFalse(isSpot);
        assertEq(recorded, shares);
        assertEq(perp.sharesOf(address(manager)), shares);

        uint256 quoteBefore = quote.balanceOf(alice);
        vm.prank(alice);
        uint256 quoteOut = manager.decreasePerp(tokenId, shares, 0, alice);
        assertEq(quoteOut, 100_000 ether);
        assertEq(quote.balanceOf(alice), quoteBefore + quoteOut);
    }

    function test_perpAndSpotEntryPointsAreNotInterchangeable() public {
        vm.prank(alice);
        vm.expectRevert(DexPositionManager.UnknownPool.selector);
        manager.mintPerp(address(spot), 1000 ether, 0, alice);

        vm.prank(alice);
        vm.expectRevert(DexPositionManager.UnknownPool.selector);
        manager.mintSpot(address(perp), 1000 ether, 1000 ether, 0, 0, alice);

        vm.prank(alice);
        (uint256 tokenId,) = manager.mintPerp(address(perp), 100_000 ether, 0, alice);
        vm.prank(alice);
        vm.expectRevert(DexPositionManager.WrongPoolKind.selector);
        manager.decreaseSpot(tokenId, 1, 0, 0, alice);
    }

    // -------------------------------------------------- no fungible LP token

    function test_poolsExposeNoErc20Surface() public {
        vm.prank(alice);
        manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);
        vm.prank(alice);
        manager.mintPerp(address(perp), 100_000 ether, 0, alice);

        // The share ledger must not be reachable as a token: no transfer, no
        // approve, no allowance, no ERC-20 metadata on either pool.
        string[6] memory sigs = [
            "transfer(address,uint256)",
            "transferFrom(address,address,uint256)",
            "approve(address,uint256)",
            "allowance(address,address)",
            "totalSupply()",
            "symbol()"
        ];
        address[2] memory pools = [address(spot), address(perp)];
        for (uint256 p = 0; p < pools.length; p++) {
            for (uint256 i = 0; i < sigs.length; i++) {
                bytes memory data = i < 3
                    ? abi.encodeWithSignature(sigs[i], bob, uint256(1))
                    : (i == 3 ? abi.encodeWithSignature(sigs[i], alice, bob) : abi.encodeWithSignature(sigs[i]));
                (bool ok,) = pools[p].call(data);
                assertFalse(ok, sigs[i]);
            }
        }
    }

    function test_directPoolLpHasNonTransferableShares() public {
        // Bypassing the manager still works, but yields ledger shares with no
        // transfer path — the NFT is the only transferable representation.
        vm.startPrank(alice);
        base.approve(address(spot), type(uint256).max);
        quote.approve(address(spot), type(uint256).max);
        (uint256 liquidity,,) = spot.addLiquidity(1000 ether, 4000 ether, 0, 0, alice);
        vm.stopPrank();

        assertEq(spot.sharesOf(alice), liquidity);
        assertEq(manager.balanceOf(alice), 0);

        // Nobody else can spend them, and there is no transfer entry point.
        vm.prank(bob);
        vm.expectRevert(SpotPool.InsufficientShares.selector);
        spot.removeLiquidity(liquidity, 0, 0, bob);
    }

    // ----------------------------------------------------------- trust guard

    function test_mintSpot_revertsOnUnregisteredPool() public {
        // A look-alike pool the registry never deployed must not be able to
        // borrow the manager's token approvals.
        SpotPool rogue =
            new SpotPool(address(registry), address(0), address(0), address(base), address(quote), FEE_PPM, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(DexPositionManager.UnknownPool.selector);
        manager.mintSpot(address(rogue), 1000 ether, 4000 ether, 0, 0, alice);
    }

    // ------------------------------------------------------------------ burn

    function test_burn_onlyWhenEmpty() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 liquidity) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        vm.prank(alice);
        vm.expectRevert(DexPositionManager.PositionNotEmpty.selector);
        manager.burn(tokenId);

        vm.prank(alice);
        manager.decreaseSpot(tokenId, liquidity, 0, 0, alice);
        vm.prank(alice);
        manager.burn(tokenId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        manager.ownerOf(tokenId);
    }

    // -------------------------------------------------------------- metadata

    function test_tokenURI_isFullyOnChain() public {
        vm.prank(alice);
        (uint256 tokenId,) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);

        string memory uri = manager.tokenURI(tokenId);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        assertGt(bytes(uri).length, 1000); // envelope + embedded SVG
        console.log("TOKENURI_SPOT", uri);
    }

    function test_tokenURI_perpCardDiffersFromSpot() public {
        vm.prank(alice);
        (uint256 spotId,) = manager.mintSpot(address(spot), 1000 ether, 4000 ether, 0, 0, alice);
        vm.prank(alice);
        (uint256 perpId,) = manager.mintPerp(address(perp), 100_000 ether, 0, alice);

        assertTrue(
            keccak256(bytes(manager.tokenURI(spotId))) != keccak256(bytes(manager.tokenURI(perpId))),
            "spot and perp cards must not render identically"
        );
        console.log("TOKENURI_PERP", manager.tokenURI(perpId));
    }

    function test_tokenURI_revertsForNonexistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99)));
        manager.tokenURI(99);
    }

    /// Token symbols are attacker-controlled and land in both the JSON
    /// envelope and the SVG body.
    function test_symbolSanitizationStripsMarkupAndQuotes() public view {
        assertEq(harness.sanitize('"><script>x'), "scriptx");
        assertEq(harness.sanitize("USDC"), "USDC");
        assertEq(harness.sanitize("wstETH-1.0_a"), "wstETH-1.0");
        assertEq(harness.sanitize("VeryLongSymbolName"), "VeryLongSy"); // capped at 10
        assertEq(harness.sanitize("</text>"), "text");
        // Junk prefix must not eat the real symbol via the length cap.
        assertEq(harness.sanitize('"""""""""USDC'), "USDC");
        assertEq(harness.sanitize(unicode"→←↔"), ""); // non-ASCII dropped entirely
    }

    function test_symbolFallsBackToShortAddressWhenUnusable() public view {
        // Reverting symbol(), and a symbol that sanitizes to nothing.
        assertEq(harness.symbolOf(address(noSymbol)), _shortAddr(address(noSymbol)));
        assertEq(harness.symbolOf(address(emptySymbol)), _shortAddr(address(emptySymbol)));
        assertEq(harness.symbolOf(address(base)), base.symbol());
    }

    function test_tokenURI_survivesHostileTokenSymbols() public {
        SpotPool hostilePool = SpotPool(registry.createSpotPool(address(hostile), address(noSymbol), FEE_PPM, 1e15));
        hostile.mint(alice, 1000 ether);
        noSymbol.mint(alice, 1000 ether);

        vm.startPrank(alice);
        hostile.approve(address(manager), type(uint256).max);
        noSymbol.approve(address(manager), type(uint256).max);
        (uint256 tokenId,) = manager.mintSpot(address(hostilePool), 100 ether, 100 ether, 0, 0, alice);
        vm.stopPrank();

        string memory uri = manager.tokenURI(tokenId);
        assertGt(bytes(uri).length, 1000);
        console.log("TOKENURI_HOSTILE", uri);
    }

    /// Motion is CSS, not SMIL, precisely so it can be switched off.
    function test_cardMotionRespectsReducedMotion() public view {
        string memory css = harness.style();
        assertTrue(_contains(css, "@media(prefers-reduced-motion:reduce)"), "no reduced-motion guard");
        assertTrue(_contains(css, "animation:none"), "guard does not stop the animation");
        assertTrue(_contains(css, ".spin"), "no rosette rule");
        assertFalse(_contains(css, "sheen"), "sheen was removed from the design");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            uint256 j;
            while (j < n.length && h[i + j] == n[j]) {
                j++;
            }
            if (j == n.length) return true;
        }
        return false;
    }

    function _prefix(string memory value, uint256 n) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = input[i];
        }
        return string(out);
    }

    function _shortAddr(address value) internal pure returns (string memory) {
        bytes memory hexed = bytes(vm.toString(value));
        bytes memory out = new bytes(13);
        for (uint256 i = 0; i < 6; i++) {
            out[i] = hexed[i];
        }
        out[6] = 0xE2;
        out[7] = 0x80;
        out[8] = 0xA6;
        for (uint256 i = 0; i < 4; i++) {
            out[9 + i] = hexed[hexed.length - 4 + i];
        }
        return _lowercase(string(out));
    }

    function _lowercase(string memory value) internal pure returns (string memory) {
        bytes memory b = bytes(value);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}

/// @dev Exposes the metadata internals so sanitization can be asserted
/// directly instead of through base64.
contract PositionManagerHarness is DexPositionManager {
    constructor(address registry_) DexPositionManager(registry_) {}

    function sanitize(string memory raw) external pure returns (string memory) {
        return _sanitize(raw);
    }

    function symbolOf(address token) external view returns (string memory) {
        return _symbolOf(token);
    }

    function style() external pure returns (string memory) {
        return _style();
    }
}

contract HostileSymbolERC20 is MockERC20 {
    constructor() MockERC20("Hostile", "H", 18) {}

    function symbol() public pure override returns (string memory) {
        return '"><script>x</script>';
    }
}

contract RevertingSymbolERC20 is MockERC20 {
    constructor() MockERC20("NoSymbol", "N", 18) {}

    function symbol() public pure override returns (string memory) {
        revert("no symbol");
    }
}

contract EmptySymbolERC20 is MockERC20 {
    constructor() MockERC20("Empty", "E", 18) {}

    function symbol() public pure override returns (string memory) {
        return unicode"→→→";
    }
}
