// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {IPerpPool} from "./interfaces/IPerpPool.sol";

/// @notice ERC-721 wrapper that turns pool LP shares into transferable
/// position NFTs, mirroring Uniswap V3's NonfungiblePositionManager: the NFT
/// lives in periphery, the pools only keep a non-transferable share ledger.
/// Since the pools expose no fungible LP token, this NFT is the only
/// transferable representation of a liquidity position.
///
/// The manager custodies the pool's LP shares and records how many back each
/// tokenId. Spot fees auto-compound into the pool reserves and perp fees into
/// `totalLiquidity`, so a position accrues fees through share value — there is
/// no separate `collect()` to call.
///
/// Every pool address is checked against the registry before the manager will
/// touch it: without that, a caller could point the manager at a contract that
/// merely looks like a pool and drain approvals.
contract DexPositionManager is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        address pool;
        bool isSpot;
        uint256 liquidity; // pool LP shares custodied for this tokenId
    }

    address public immutable registry;
    uint256 public nextTokenId = 1;

    mapping(uint256 => Position) public positions;

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPool();
    error WrongPoolKind();
    error NotAuthorized();
    error InsufficientPositionLiquidity();
    error PositionNotEmpty();

    event PositionMinted(uint256 indexed tokenId, address indexed pool, address indexed to, uint256 liquidity);
    event LiquidityIncreased(uint256 indexed tokenId, uint256 liquidityAdded, uint256 liquidityAfter);
    event LiquidityDecreased(uint256 indexed tokenId, uint256 liquidityRemoved, uint256 liquidityAfter);
    event PositionBurned(uint256 indexed tokenId);

    constructor(address registry_) ERC721("Series9 DEX Position", "S9-POS") {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ------------------------------------------------------------------ spot

    function mintSpot(
        address pool,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 tokenId, uint256 liquidity) {
        _requireSpotPool(pool);
        liquidity = _addSpot(pool, amount0Desired, amount1Desired, amount0Min, amount1Min);
        tokenId = _mintPosition(pool, true, liquidity, to);
    }

    /// @dev Deliberately callable by anyone, as in Uniswap V3: adding
    /// liquidity to someone else's position only ever benefits its holder.
    function increaseSpot(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 liquidity) {
        Position storage pos = positions[tokenId];
        _requireOwned(tokenId);
        if (!pos.isSpot) revert WrongPoolKind();
        liquidity = _addSpot(pos.pool, amount0Desired, amount1Desired, amount0Min, amount1Min);
        pos.liquidity += liquidity;
        emit LiquidityIncreased(tokenId, liquidity, pos.liquidity);
    }

    function decreaseSpot(uint256 tokenId, uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _authorizedPosition(tokenId, true);
        if (liquidity == 0) revert ZeroAmount();
        if (liquidity > pos.liquidity) revert InsufficientPositionLiquidity();
        pos.liquidity -= liquidity;
        (amount0, amount1) = ISpotPool(pos.pool).removeLiquidity(liquidity, amount0Min, amount1Min, to);
        emit LiquidityDecreased(tokenId, liquidity, pos.liquidity);
    }

    // ------------------------------------------------------------------ perp

    function mintPerp(address pool, uint256 quoteIn, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 tokenId, uint256 shares)
    {
        _requirePerpPool(pool);
        shares = _addPerp(pool, quoteIn, minShares);
        tokenId = _mintPosition(pool, false, shares, to);
    }

    function increasePerp(uint256 tokenId, uint256 quoteIn, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        Position storage pos = positions[tokenId];
        _requireOwned(tokenId);
        if (pos.isSpot) revert WrongPoolKind();
        shares = _addPerp(pos.pool, quoteIn, minShares);
        pos.liquidity += shares;
        emit LiquidityIncreased(tokenId, shares, pos.liquidity);
    }

    function decreasePerp(uint256 tokenId, uint256 shares, uint256 minQuoteOut, address to)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        Position storage pos = _authorizedPosition(tokenId, false);
        if (shares == 0) revert ZeroAmount();
        if (shares > pos.liquidity) revert InsufficientPositionLiquidity();
        pos.liquidity -= shares;
        quoteOut = IPerpPool(pos.pool).removeLiquidity(shares, minQuoteOut, to);
        emit LiquidityDecreased(tokenId, shares, pos.liquidity);
    }

    // ------------------------------------------------------------------ burn

    function burn(uint256 tokenId) external {
        address owner = _requireOwned(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert NotAuthorized();
        if (positions[tokenId].liquidity != 0) revert PositionNotEmpty();
        delete positions[tokenId];
        _burn(tokenId);
        emit PositionBurned(tokenId);
    }

    // ------------------------------------------------------------- internals

    function _mintPosition(address pool, bool isSpot, uint256 liquidity, address to)
        internal
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert ZeroAddress();
        tokenId = nextTokenId++;
        positions[tokenId] = Position({pool: pool, isSpot: isSpot, liquidity: liquidity});
        _safeMint(to, tokenId);
        emit PositionMinted(tokenId, pool, to, liquidity);
    }

    function _addSpot(
        address pool,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 liquidity) {
        address token0 = ISpotPool(pool).token0();
        address token1 = ISpotPool(pool).token1();
        uint256 have0 = _pullAndApprove(token0, pool, amount0Desired);
        uint256 have1 = _pullAndApprove(token1, pool, amount1Desired);
        (liquidity,,) = ISpotPool(pool).addLiquidity(have0, have1, amount0Min, amount1Min, address(this));
        _settle(token0, pool);
        _settle(token1, pool);
    }

    function _addPerp(address pool, uint256 quoteIn, uint256 minShares) internal returns (uint256 shares) {
        address quoteToken = IPerpPool(pool).quoteToken();
        uint256 have = _pullAndApprove(quoteToken, pool, quoteIn);
        shares = IPerpPool(pool).addLiquidity(have, minShares, address(this));
        _settle(quoteToken, pool);
    }

    /// @dev Pull `amount` from the caller and approve the pool for whatever
    /// actually arrived (fee-on-transfer tokens deliver less than requested).
    function _pullAndApprove(address token, address pool, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();
        IERC20(token).forceApprove(pool, received);
    }

    /// @dev The pool takes only the ratio-optimal amount, so drop the leftover
    /// approval and hand the remainder back. The manager holds pool LP shares
    /// between calls, never the underlying tokens, so sweeping the whole
    /// balance is safe.
    function _settle(address token, address pool) internal {
        IERC20(token).forceApprove(pool, 0);
        uint256 leftover = IERC20(token).balanceOf(address(this));
        if (leftover > 0) IERC20(token).safeTransfer(msg.sender, leftover);
    }

    function _authorizedPosition(uint256 tokenId, bool isSpot) internal view returns (Position storage pos) {
        address owner = _requireOwned(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert NotAuthorized();
        pos = positions[tokenId];
        if (pos.isSpot != isSpot) revert WrongPoolKind();
    }

    function _requireSpotPool(address pool) internal view {
        if (!IDexRegistry(registry).isSpotPool(pool)) revert UnknownPool();
    }

    function _requirePerpPool(address pool) internal view {
        IDexRegistry reg = IDexRegistry(registry);
        if (reg.poolPairId(pool) == bytes32(0) || reg.isSpotPool(pool)) revert UnknownPool();
    }

    // -------------------------------------------------------------- metadata

    /// @notice Fully on-chain metadata: a base64 JSON envelope wrapping a
    /// base64 SVG card, so the artwork survives without any hosting.
    ///
    /// The card shows only values that cannot change for the position (pair,
    /// pool kind, fee, pool address). Share size is deliberately left off:
    /// marketplaces cache the rendered image, and a cached liquidity number
    /// goes stale the moment the holder adds or removes.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Position memory pos = positions[tokenId];

        (address tokenA, address tokenB, uint32 feePpm, bytes32 pairId) = _poolFacts(pos);
        string memory symbolA = _symbolOf(tokenA);
        string memory symbolB = _symbolOf(tokenB);
        string memory kind = pos.isSpot ? "SPOT" : "PERP";
        string memory fee = _percent(feePpm);
        string memory pair = string.concat(symbolA, " / ", symbolB);

        string memory json = string.concat(
            '{"name":"Series9 ',
            kind,
            " ",
            pair,
            " #",
            Strings.toString(tokenId),
            '","description":"Liquidity position in a Series9 DEX ',
            pos.isSpot ? "spot" : "perp",
            " pool. The pool holds no fungible LP token; this NFT is the only transferable claim on the underlying shares.",
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(pos.pool, kind, symbolA, symbolB, fee, pairId))),
            '","attributes":[',
            '{"trait_type":"Pool Type","value":"',
            kind,
            '"},{"trait_type":"Pair","value":"',
            pair,
            '"},{"trait_type":"Fee","value":"',
            fee,
            '"},{"trait_type":"Pool","value":"',
            Strings.toHexString(uint160(pos.pool), 20),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _poolFacts(Position memory pos)
        internal
        view
        returns (address tokenA, address tokenB, uint32 feePpm, bytes32 pairId)
    {
        if (pos.isSpot) {
            ISpotPool pool = ISpotPool(pos.pool);
            return (pool.token0(), pool.token1(), pool.lpFeeRatePpm(), pool.pairId());
        }
        IPerpPool pool_ = IPerpPool(pos.pool);
        // Base first: a perp position is quoted as base-per-quote, so the pair
        // reads the same way round as the spot pool it marks against.
        return (pool_.baseToken(), pool_.quoteToken(), pool_.lpFeeRatePpm(), pool_.pairId());
    }

    /// @dev Black ground, engraved gold rosette, white type. The pair id no
    /// longer picks a free hue: it only slides the gold along a champagne-to-
    /// amber band and rotates the engraving, so every card reads as the same
    /// house style while no two pairs engrave identically.
    function _svg(
        address pool,
        string memory kind,
        string memory symbolA,
        string memory symbolB,
        string memory fee,
        bytes32 pairId
    ) internal pure returns (string memory) {
        uint256 seed = uint256(pairId);
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='290' height='500' viewBox='0 0 290 500'>",
            _defs(Strings.toString(36 + (seed % 16))),
            "<rect width='290' height='500' rx='16' fill='url(#bg)'/>",
            _engraving(seed % 30),
            "<rect x='9.5' y='9.5' width='271' height='481' rx='12' fill='none' stroke='url(#au)'/>",
            "<rect x='15.5' y='15.5' width='259' height='469' rx='8' fill='none' stroke='url(#au)' stroke-opacity='.4' stroke-width='.6'/>",
            _svgText(pool, kind, symbolA, symbolB, fee),
            "</svg>"
        );
    }

    function _defs(string memory gold) internal pure returns (string memory) {
        // Five stops so the flat fill reads as raked foil rather than paint.
        return string.concat(
            "<defs><linearGradient id='au' x1='0' y1='0' x2='.9' y2='1'>",
            "<stop offset='0' stop-color='hsl(",
            gold,
            ",55%,34%)'/>",
            "<stop offset='.32' stop-color='hsl(",
            gold,
            ",74%,64%)'/>",
            "<stop offset='.5' stop-color='hsl(",
            gold,
            ",88%,88%)'/>",
            "<stop offset='.68' stop-color='hsl(",
            gold,
            ",72%,57%)'/>",
            "<stop offset='1' stop-color='hsl(",
            gold,
            ",58%,30%)'/></linearGradient>",
            "<radialGradient id='bg' cx='.5' cy='.3' r='.95'>",
            "<stop offset='0' stop-color='#191612'/><stop offset='1' stop-color='#08080A'/>",
            "</radialGradient></defs>",
            _style()
        );
    }

    /// @dev CSS rather than SMIL so the motion can be switched off for
    /// viewers who ask for reduced motion. Frame zero is the static card
    /// with the rosette unrotated, so a marketplace that renders a still
    /// loses nothing.
    function _style() internal pure returns (string memory) {
        return string.concat(
            "<style>",
            ".spin{animation:sp 140s linear infinite}",
            "@keyframes sp{to{transform:rotate(360deg)}}",
            "@media(prefers-reduced-motion:reduce){.spin{animation:none}}",
            "</style>"
        );
    }

    /// @dev Engine-turned rosette, the guilloche of a share certificate.
    function _engraving(uint256 rotation) internal pure returns (string memory) {
        string memory rings;
        for (uint256 i = 0; i < 6; i++) {
            rings = string.concat(
                rings, "<ellipse rx='126' ry='49' transform='rotate(", Strings.toString(rotation + i * 30), ")'/>"
            );
        }
        return string.concat(
            "<g transform='translate(145,232)' fill='none' stroke='url(#au)' stroke-width='.7' opacity='.22'>",
            "<g class='spin'>",
            rings,
            "<circle r='7'/></g></g>"
        );
    }

    function _svgText(address pool, string memory kind, string memory symbolA, string memory symbolB, string memory fee)
        internal
        pure
        returns (string memory)
    {
        string memory serif = "font-family='Georgia,Times New Roman,serif'";
        string memory sans = "font-family='Helvetica Neue,Arial,sans-serif'";
        return string.concat(
            // Sans for the wordmark: Georgia sets old-style figures, which
            // drops the 9 below the caps and reads as "SERIES-subscript-9".
            "<text x='145' y='58' text-anchor='middle' ",
            sans,
            " font-weight='500' font-size='13.5' letter-spacing='6.5' fill='url(#au)'>SERIES9</text>",
            "<path d='M101 72 H189' stroke='url(#au)' stroke-opacity='.55'/>",
            "<text x='145' y='90' text-anchor='middle' ",
            sans,
            " font-size='7' letter-spacing='3.4' fill='#F7F5F0' fill-opacity='.5'>LIQUIDITY POSITION</text>",
            "<text x='145' y='212' text-anchor='middle' ",
            serif,
            " font-size='32' fill='#F9F7F2'>",
            symbolA,
            "</text>",
            "<path d='M70 232 H130 M160 232 H220' stroke='url(#au)' stroke-opacity='.6'/>",
            "<path d='M145 226 l5 6 -5 6 -5 -6z' fill='url(#au)'/>",
            "<text x='145' y='270' text-anchor='middle' ",
            serif,
            " font-size='32' fill='#F9F7F2'>",
            symbolB,
            "</text>",
            "<text x='145' y='300' text-anchor='middle' ",
            sans,
            " font-size='8.5' letter-spacing='4.2' fill='url(#au)'>",
            kind,
            "</text>",
            _svgRow(sans, "FEE", fee, 426),
            _svgRow(sans, "POOL", _shortAddress(pool), 460)
        );
    }

    function _svgRow(string memory sans, string memory label, string memory value, uint256 y)
        internal
        pure
        returns (string memory)
    {
        string memory ys = Strings.toString(y);
        return string.concat(
            "<path d='M30 ",
            Strings.toString(y - 16),
            " H260' stroke='#F7F5F0' stroke-opacity='.12'/>",
            "<text x='30' y='",
            ys,
            "' ",
            sans,
            " font-size='7.5' letter-spacing='2.6' fill='url(#au)'>",
            label,
            "</text>",
            "<text x='260' y='",
            ys,
            "' text-anchor='end' font-family='ui-monospace,Menlo,monospace' font-size='10.5' fill='#F9F7F2'>",
            value,
            "</text>"
        );
    }

    /// @dev ppm to a percent string with four decimals, exact for every fee
    /// the registry accepts (3000 ppm renders as "0.3000%").
    function _percent(uint32 ppm) internal pure returns (string memory) {
        uint256 whole = uint256(ppm) / 10_000;
        bytes memory digits = bytes(Strings.toString(uint256(ppm) % 10_000));
        bytes memory padded = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < digits.length; i++) {
            padded[4 - digits.length + i] = digits[i];
        }
        return string.concat(Strings.toString(whole), ".", string(padded), "%");
    }

    function _shortAddress(address value) internal pure returns (string memory) {
        bytes memory hexed = bytes(Strings.toHexString(uint160(value), 20));
        bytes memory out = new bytes(13);
        for (uint256 i = 0; i < 6; i++) {
            out[i] = hexed[i]; // "0x" + first 4 nibbles
        }
        out[6] = 0xE2;
        out[7] = 0x80;
        out[8] = 0xA6; // U+2026 horizontal ellipsis
        for (uint256 i = 0; i < 4; i++) {
            out[9 + i] = hexed[hexed.length - 4 + i];
        }
        return string(out);
    }

    /// @dev Token symbols are attacker-controlled strings that end up inside
    /// both the JSON envelope and the SVG, so anything outside a conservative
    /// alphabet is dropped rather than escaped. A token that reverts, returns
    /// nothing, or is not a contract falls back to its short address.
    function _symbolOf(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory raw) {
            string memory cleaned = _sanitize(raw);
            if (bytes(cleaned).length > 0) return cleaned;
        } catch {}
        return _shortAddress(token);
    }

    function _sanitize(string memory raw) internal pure returns (string memory) {
        bytes memory input = bytes(raw);
        // Count kept characters, not scanned ones: a symbol prefixed with
        // junk must not lose its tail to the length cap. Scanning is still
        // bounded so an absurdly long symbol cannot burn unbounded gas.
        uint256 scan = input.length > 64 ? 64 : input.length;
        bytes memory out = new bytes(10);
        uint256 n;
        for (uint256 i = 0; i < scan && n < 10; i++) {
            bytes1 c = input[i];
            bool keep = (c >= 0x30 && c <= 0x39) // 0-9
                || (c >= 0x41 && c <= 0x5A) // A-Z
                || (c >= 0x61 && c <= 0x7A) // a-z
                || c == 0x2E || c == 0x2D || c == 0x5F; // . - _
            if (keep) {
                out[n++] = c;
            }
        }
        assembly {
            mstore(out, n)
        }
        return string(out);
    }
}
