// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {PerpParams} from "./interfaces/IPerpPool.sol";
import {IPair} from "./interfaces/IPair.sol";
import {Pausing} from "./libraries/Pausing.sol";

interface ISpotPoolFactory {
    function deploy(address treasury, address token0, address token1, uint32 lpFeeRatePpm)
        external
        returns (address pool);
}

interface IPerpPoolFactory {
    function deploy(
        address treasury,
        address spotPool,
        address baseToken,
        address quoteToken,
        uint32 lpFeeRatePpm,
        PerpParams calldata params
    ) external returns (address pool);
}

/// @notice One Pair contract per token pair (DEX.md §3), CREATE2-deployed by
/// `DexRegistry.createPair`. Owns pool creation and the on-chain orderbook.
/// This contract's own address is the pair's identifier, and it carries no
/// per-pair parameter: order prices sit on a decimal grid
/// (`MAX_PRICE_SIG_DIGITS`) that is a pure function of the price rather than
/// a tick some first caller gets to fix forever.
///
/// Prices are raw quote units per raw base unit, scaled by 1e36 (`priceX36`).
///
/// An order fills from two sources, whichever is better at the margin.
///
/// Against the pools, each hop picks whichever of this pair's spot pools has
/// the most room left before its *average* post-fee fill price would reach
/// the target, and drains it to exactly that point; visiting the roomiest
/// pool first is what maximises how much of the order clears inside the hop
/// budget. The target is the order's own limit, or the opposite side of the
/// book when the book is crossed — so a pool is used only while it beats the
/// standing counterparty.
///
/// Against the book, a crossed ask and bid fill each other directly at the
/// midpoint of their two limits, paying no pool fee. Together the two rules
/// mean an order never routes past a counterparty that is offering better,
/// and never takes the book when a pool is cheaper.
///
/// A new order is matched as it is placed. It only rests once nothing
/// crosses it, so no one gets to pick the moment a marketable order fills.
///
/// `maxFills` bounds pool-hops and direct fills, not orders — a single order
/// filled across three pools spends three fills. Dead-node cleanup has its
/// own allowance of `POPS_PER_FILL` per fill.
contract Pair is IPair, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Order {
        address maker;
        Side side;
        Status status;
        uint64 expiry;
        uint256 priceX36;
        uint256 amountBase; // SELL: credited escrow (fee-on-transfer aware); BUY: nominal target
        uint256 filledBase;
        uint256 escrowRemaining; // SELL: base left to sell; BUY: quote left to spend
        uint256 nextInLevel; // FIFO link
    }

    /// @dev Work one call to `_match` may do. Fills (pool hops, direct
    /// fills, dust closes) and pops (dead or expired heads) are counted
    /// apart; see `POPS_PER_FILL`.
    struct Budget {
        uint256 fills;
        uint256 pops;
        uint256 maxFills;
        uint256 maxPops;
    }

    /// @dev Outcome of one pool hop for an order.
    enum Hop {
        FILLED,
        NOT_CROSSABLE, // no pool has room before the order's target price
        TOO_SMALL // a pool has room, but the order's remainder is too small to clear its limit there
    }

    struct Level {
        bool active;
        uint256 totalBase; // advisory sum of open remainders (may include expired-not-yet-removed)
        uint256 headOrder;
        uint256 tailOrder;
        uint256 prevPrice; // toward best
        uint256 nextPrice; // toward worse
    }

    uint256 internal constant PPM = 1e6;
    uint256 internal constant PRICE_SCALE = 1e36;

    // Protocol-wide fee-rate bounds, both spot and perp: no governance knob,
    // same hardcoded range every pair gets.
    uint32 public constant MIN_LP_FEE_PPM = 1;
    uint32 public constant MAX_LP_FEE_PPM = 10_000;

    // The four canonical spot fee tiers. Always creatable and never charged
    // against the custom budget, which is what makes a pair ungriefable:
    // squatting one of these is pointless because the squatter's pool *is*
    // the canonical pool for that tier — anyone may add liquidity to it and
    // anyone may route through it.
    uint32 public constant FEE_TIER_LOWEST = 100; // 0.01%
    uint32 public constant FEE_TIER_LOW = 500; // 0.05%
    uint32 public constant FEE_TIER_MEDIUM = 3_000; // 0.30%
    uint32 public constant FEE_TIER_HIGH = 10_000; // 1.00%

    // Any other rate in [MIN_LP_FEE_PPM, MAX_LP_FEE_PPM] is a custom tier.
    // Burning all twelve costs ~12 pool deployments and only removes the
    // exotic rates; the four canonical tiers survive, so the pair stays
    // usable no matter who got there first.
    // ponytail: matching-loop gas scales with 4 + this
    uint256 public constant MAX_CUSTOM_SPOT_POOLS = 12;

    /// @notice Orders sit on a decimal grid rather than a per-pair tick:
    /// `priceX36` may carry at most this many significant decimal digits.
    /// The granularity is relative, so WBTC/USDC (raw price ~6e2, 6e38 at
    /// X36) and an 18-decimal meme coin against USDC at $0.00001 (raw 1e-17,
    /// 1e19 at X36) both get six digits — something no absolute tick
    /// constant can do. And because it is a pure function of the price,
    /// there is no per-pair value for a first caller to squat.
    uint256 public constant MAX_PRICE_SIG_DIGITS = 6;
    /// @notice Highest price an order may carry. Covers a 0-decimal token
    /// worth 1e9 units of an 18-decimal quote (raw 1e27) with nine orders of
    /// magnitude to spare, and keeps every product in matching inside 256
    /// bits — an unbounded price let one wei-sized order overflow the
    /// crossability check and revert every match on the pair.
    uint256 public constant MAX_PRICE_X36 = 1e72;
    /// @notice Largest order size, and largest buy escrow, in raw units.
    uint256 public constant MAX_ORDER_AMOUNT = type(uint128).max;
    /// @notice Matching budget a new order spends at placement.
    uint256 public constant PLACE_MATCH_FILLS = 16;
    /// @notice Dead or expired heads a match may pop per unit of its fill
    /// budget. Pops still have to be bounded — a level stuffed with
    /// cancelled orders would otherwise make every match walk all of them —
    /// but charging them against fills let such a level use up a new order's
    /// whole placement budget and leave it resting while still marketable,
    /// which is the sandwich placement-time matching exists to prevent.
    uint256 public constant POPS_PER_FILL = 8;
    /// @notice An order's remainder under this many raw units of base, or of
    /// quote at its price, that cannot clear its limit against a crossable
    /// pool is closed as dust. A pool rounds its effective input and its
    /// output down by up to a unit each, which can cost a remainder this
    /// small more than a basis point.
    uint256 public constant DUST_UNITS = 1e4;

    address public immutable registry;
    address public immutable base; // token0, sorted
    address public immutable quote; // token1
    /// @notice Spot factory and treasury as of this pair's deployment, fixed
    /// for its lifetime. The pair approves its spot pools to move escrow, so
    /// where they come from cannot be something the registry can change
    /// later. Perp pools never touch the pair's escrow, so the perp factory
    /// is read from the registry at creation — a pair made before perps were
    /// enabled can still get them.
    address public immutable spotPoolFactory;
    address public immutable treasury;
    /// @notice Smallest order notional: 1e-4 of one quote token, by the
    /// quote's own decimals. A fixed raw amount was meaningless across
    /// tokens — 1e4 wei of an 18-decimal token is nothing, of a 2-decimal one
    /// it is a hundred tokens.
    uint256 public immutable minQuoteNotional;

    address[] public spotPools;
    address[] public perpPools;
    uint256 public customSpotPools; // spotPools created off the canonical tiers
    mapping(address => bool) public isSpotPool;
    mapping(uint32 => bool) public spotFeeUsed;
    /// @notice One perp pool per full configuration. Perp pools are never
    /// iterated, so there is no budget to protect; deduplicating on fee alone
    /// only let the first creator decide the oracle and risk parameters of
    /// that fee for everyone.
    mapping(bytes32 => bool) public perpConfigUsed;

    uint256 public bestBidPrice; // highest bid, 0 = empty
    uint256 public bestAskPrice; // lowest ask, 0 = empty
    mapping(uint256 => Level) internal bidLevels;
    mapping(uint256 => Level) internal askLevels;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;
    mapping(address => uint256[]) internal _makerOrders;

    /// @notice Proceeds and refunds a direct transfer could not deliver — a
    /// maker a token has blocklisted, say. Matching pays makers as it goes,
    /// and one transfer that reverts would otherwise revert the match for
    /// every order on the pair.
    mapping(address => mapping(address => uint256)) public claimable; // account => token => amount
    mapping(address => uint256) public totalClaimable; // token => amount

    error ZeroAmount();
    error ZeroAddress();
    error InvalidPrice();
    error InvalidAmount();
    error InvalidExpiry();
    error NotionalTooSmall();
    error NotMaker();
    error OrderNotOpen();
    error OrderNotExpired();
    error OnlySpotPool();
    error OnlySelf();
    error InvalidFeeRate();
    error DuplicateFeeRate();
    error DuplicatePerpPool();
    error FactoryNotSet();
    error InvalidQuoteToken();
    error UnknownSpotPool();
    error TooManyCustomSpotPools();
    error PoolMisbehaved();

    event SpotPoolCreated(address indexed pool, address indexed creator, uint32 lpFeeRatePpm);
    event PerpPoolCreated(address indexed pool, address indexed creator, address quoteToken, uint32 lpFeeRatePpm);
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        uint256 priceX36,
        uint256 amountBase,
        uint256 escrowed,
        uint64 expiry
    );
    event OrderFilled(uint256 indexed orderId, address indexed pool, uint256 baseFilled, uint256 quoteAmount);
    event OrderClosed(uint256 indexed orderId, Status status, uint256 refunded);
    event PaymentDeferred(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed token, address to, uint256 amount);

    constructor(address registry_, address token0_, address token1_) {
        registry = registry_;
        base = token0_;
        quote = token1_;
        spotPoolFactory = IDexRegistry(registry_).spotPoolFactory();
        treasury = IDexRegistry(registry_).treasury();
        minQuoteNotional = _minNotional(token1_);
    }

    /// @dev `decimals()` is optional in ERC-20 and may be missing, revert or
    /// return nonsense; any of those falls back to 18.
    function _minNotional(address token) private view returns (uint256) {
        uint256 decimals = 18;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (ok && data.length >= 32) decimals = Math.min(abi.decode(data, (uint256)), 36);
        return decimals > 4 ? 10 ** (decimals - 4) : 1;
    }

    // ---------------------------------------------------------- pool creation

    /// @notice One spot pool per fee rate. The four canonical tiers are
    /// always available; every other rate consumes one of the twelve custom
    /// slots. Carries no per-pair parameter, so there is nothing to squat.
    function createSpotPool(uint32 lpFeeRatePpm) external returns (address pool) {
        Pausing.requireNotPaused(registry);
        if (lpFeeRatePpm < MIN_LP_FEE_PPM || lpFeeRatePpm > MAX_LP_FEE_PPM) revert InvalidFeeRate();
        if (spotFeeUsed[lpFeeRatePpm]) revert DuplicateFeeRate();
        if (!isCanonicalFeeTier(lpFeeRatePpm)) {
            if (customSpotPools >= MAX_CUSTOM_SPOT_POOLS) revert TooManyCustomSpotPools();
            customSpotPools++;
        }
        if (spotPoolFactory == address(0)) revert FactoryNotSet();
        pool = ISpotPoolFactory(spotPoolFactory).deploy(treasury, base, quote, lpFeeRatePpm);
        spotPools.push(pool);
        isSpotPool[pool] = true;
        spotFeeUsed[lpFeeRatePpm] = true;
        IDexRegistry(registry).registerPool(pool, true);
        emit SpotPoolCreated(pool, msg.sender, lpFeeRatePpm);
    }

    function createPerpPool(address quoteToken, address spotPool, uint32 lpFeeRatePpm, PerpParams calldata params)
        external
        returns (address pool)
    {
        Pausing.requireNotPaused(registry);
        if (lpFeeRatePpm < MIN_LP_FEE_PPM || lpFeeRatePpm > MAX_LP_FEE_PPM) revert InvalidFeeRate();
        if (quoteToken != base && quoteToken != quote) revert InvalidQuoteToken();
        if (!isSpotPool[spotPool]) revert UnknownSpotPool();
        // Risk parameters are the perp pool's own invariants; its constructor
        // rejects a bad set (`PerpPool.InvalidPerpParams`).
        bytes32 config = keccak256(abi.encode(quoteToken, spotPool, lpFeeRatePpm, params));
        if (perpConfigUsed[config]) revert DuplicatePerpPool();

        address factory = IDexRegistry(registry).perpPoolFactory();
        if (factory == address(0)) revert FactoryNotSet();
        address baseToken = quoteToken == base ? quote : base;
        pool = IPerpPoolFactory(factory).deploy(treasury, spotPool, baseToken, quoteToken, lpFeeRatePpm, params);
        perpPools.push(pool);
        perpConfigUsed[config] = true;
        // The perp reads its mark from this pool's epoch observations.
        ISpotPool(spotPool).enableOracle();
        IDexRegistry(registry).registerPool(pool, false);
        emit PerpPoolCreated(pool, msg.sender, quoteToken, lpFeeRatePpm);
    }

    function spotPoolsLength() external view returns (uint256) {
        return spotPools.length;
    }

    function perpPoolsLength() external view returns (uint256) {
        return perpPools.length;
    }

    // ---------------------------------------------------------------- views

    function bestBid() external view returns (uint256 priceX36, uint256 totalBase) {
        priceX36 = bestBidPrice;
        totalBase = priceX36 == 0 ? 0 : bidLevels[priceX36].totalBase;
    }

    function bestAsk() external view returns (uint256 priceX36, uint256 totalBase) {
        priceX36 = bestAskPrice;
        totalBase = priceX36 == 0 ? 0 : askLevels[priceX36].totalBase;
    }

    function levelOf(Side side, uint256 priceX36)
        external
        view
        returns (bool active, uint256 totalBase, uint256 nextPrice)
    {
        Level storage level = side == Side.BUY ? bidLevels[priceX36] : askLevels[priceX36];
        return (level.active, level.totalBase, level.nextPrice);
    }

    /// @notice Walk one side of the book outward from `startPrice` (0 starts
    /// at the best price). `cursor` is what to pass as the next call's
    /// `startPrice`; 0 means the side is exhausted. A `startPrice` that is no
    /// longer an active level restarts from the best price rather than
    /// returning nothing.
    function levels(Side side, uint256 startPrice, uint256 count)
        external
        view
        returns (uint256[] memory prices, uint256[] memory totalBase, uint256 cursor)
    {
        mapping(uint256 => Level) storage book = side == Side.BUY ? bidLevels : askLevels;
        uint256 best = side == Side.BUY ? bestBidPrice : bestAskPrice;
        // A cursor handed back by an earlier call can be gone by the time it is
        // used again — anyone may match, and a fully filled level is unlinked.
        // `_unlinkLevel` deletes the level, so its `nextPrice` is gone with it
        // and there is nothing to resume from; restarting at the best price
        // repeats a page but never hides depth, where trusting the dead cursor
        // would return an empty page and read as "side exhausted".
        cursor = (startPrice == 0 || !book[startPrice].active) ? best : startPrice;
        prices = new uint256[](count);
        totalBase = new uint256[](count);
        uint256 n;
        while (n < count && cursor != 0 && book[cursor].active) {
            prices[n] = cursor;
            totalBase[n] = book[cursor].totalBase;
            n++;
            cursor = book[cursor].nextPrice;
        }
        assembly {
            mstore(prices, n)
            mstore(totalBase, n)
        }
    }

    function ordersOfLength(address maker) external view returns (uint256) {
        return _makerOrders[maker].length;
    }

    /// @notice A page of one maker's order ids, oldest first; `orders(id)`
    /// has the rest. `start` indexes that maker's own list. Includes closed
    /// orders — the FIFO keeps them and so does this, so a front end can show
    /// fill history without replaying events.
    function orderIdsOf(address maker, uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        uint256[] storage all = _makerOrders[maker];
        uint256 len = all.length;
        if (start >= len) return new uint256[](0);
        uint256 n = Math.min(count, len - start);
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = all[start + i];
        }
    }

    function isCanonicalFeeTier(uint32 lpFeeRatePpm) public pure returns (bool) {
        return lpFeeRatePpm == FEE_TIER_LOWEST || lpFeeRatePpm == FEE_TIER_LOW || lpFeeRatePpm == FEE_TIER_MEDIUM
            || lpFeeRatePpm == FEE_TIER_HIGH;
    }

    /// @notice Whether `priceX36` is in range and on the decimal grid
    /// `placeOrder` accepts.
    ///
    /// @dev Deliberately not sharing a walk with `tickSizeAt`: folding the two
    /// together costs this function — which every `placeOrder` runs — the tick
    /// multiply it has no use for, and it bails on the first off-grid digit
    /// where a shared version has to keep going. `testGridViewsAgree` is what
    /// holds the two in lockstep, which is the job a test does better than a
    /// shared helper does.
    function priceIsValid(uint256 priceX36) public pure returns (bool) {
        if (priceX36 == 0 || priceX36 > MAX_PRICE_X36) return false;
        uint256 ceiling = 10 ** MAX_PRICE_SIG_DIGITS;
        while (priceX36 >= ceiling) {
            if (priceX36 % 10 != 0) return false;
            priceX36 /= 10;
        }
        return true;
    }

    /// @notice Smallest legal price increment at `priceX36`'s magnitude —
    /// what a per-pair `tickSize` used to be, derived rather than chosen.
    function tickSizeAt(uint256 priceX36) public pure returns (uint256 tick) {
        tick = 1;
        uint256 ceiling = 10 ** MAX_PRICE_SIG_DIGITS;
        while (priceX36 >= ceiling) {
            priceX36 /= 10;
            tick *= 10;
        }
    }

    // --------------------------------------------------------------- orders

    /// @notice Escrow and enqueue an order, then match it at once against the
    /// pools and the book. Whatever is left rests.
    ///
    /// Matching here is what makes a limit order safe to place above the
    /// market: a resting order that could already fill would wait for
    /// someone else's swap to trigger it, and that someone gets to push the
    /// pool to the order's limit first and buy back after — the order's own
    /// limit becomes the price it is filled at, inside one transaction.
    function placeOrder(Side side, uint256 priceX36, uint256 amountBase, uint64 expiry, uint256 priceHint)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        Pausing.requireNotPaused(registry);
        if (!priceIsValid(priceX36)) revert InvalidPrice();
        if (amountBase == 0 || amountBase > MAX_ORDER_AMOUNT) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (Math.mulDiv(amountBase, priceX36, PRICE_SCALE) < minQuoteNotional) revert NotionalTooSmall();

        uint256 escrowed;
        if (side == Side.SELL) {
            escrowed = _pull(base, amountBase);
            amountBase = escrowed; // fee-on-transfer: sellable = what actually arrived
            if (Math.mulDiv(amountBase, priceX36, PRICE_SCALE) < minQuoteNotional) revert NotionalTooSmall();
        } else {
            uint256 cost = Math.mulDiv(amountBase, priceX36, PRICE_SCALE, Math.Rounding.Ceil);
            if (cost > MAX_ORDER_AMOUNT) revert InvalidAmount();
            escrowed = _pull(quote, cost);
            if (escrowed == 0) revert InvalidAmount();
        }

        orderId = nextOrderId++;
        Order storage order = orders[orderId];
        order.maker = msg.sender;
        order.side = side;
        order.status = Status.OPEN;
        order.expiry = expiry;
        order.priceX36 = priceX36;
        order.amountBase = amountBase;
        order.escrowRemaining = escrowed;
        _makerOrders[msg.sender].push(orderId);

        _enqueue(side, priceX36, orderId, amountBase, priceHint);
        emit OrderPlaced(orderId, msg.sender, side, priceX36, amountBase, escrowed, expiry);
        _match(PLACE_MATCH_FILLS);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.maker != msg.sender) revert NotMaker();
        _close(orderId, order, Status.CANCELLED);
    }

    /// @notice Anyone may clear an expired order; escrow returns to the maker.
    function removeExpired(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.status != Status.OPEN) revert OrderNotOpen();
        if (order.expiry > block.timestamp) revert OrderNotExpired();
        _close(orderId, order, Status.EXPIRED);
    }

    /// @notice Withdraw proceeds or refunds that could not be sent directly,
    /// to any address — the usual reason a transfer failed is that the
    /// maker's own address is the one a token refuses.
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = claimable[msg.sender][token];
        if (amount == 0) revert ZeroAmount();
        claimable[msg.sender][token] = 0;
        totalClaimable[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit Claimed(msg.sender, token, to, amount);
    }

    // -------------------------------------------------------------- matching

    /// @notice Permissionless keeper entry point; routes across every spot
    /// pool of this pair.
    function matchOrders(uint256 maxFills) external nonReentrant {
        _match(maxFills);
    }

    /// @notice Called by a spot pool of this pair right after a user swap
    /// moved its price. Routing still spans every spot pool, not just the
    /// one that triggered — the trigger is only proof a swap just happened.
    function matchFromPool(uint256 maxFills) external nonReentrant {
        if (!isSpotPool[msg.sender]) revert OnlySpotPool();
        _match(maxFills);
    }

    function _match(uint256 maxFills) internal {
        // Matching executes trades, so it is an entry point, not an exit. A
        // maker's way out while paused is `cancelOrder`, which stays open.
        Pausing.requireNotPaused(registry);
        Budget memory b = Budget(0, 0, maxFills, maxFills * POPS_PER_FILL);
        // Asks push pools' prices down, bids push them up; a book crossed on
        // both sides may need alternating passes. Bounded by the budget.
        //
        // Pools run first, but capped at the crossing midpoint rather than at
        // the order's own limit (`_sellTarget`/`_buyTarget`). A pool is
        // therefore only ever used while it beats what the book would pay,
        // and `_matchBook` takes over from the point where it stops — so a
        // fill always comes from whichever source is better at the margin,
        // and never routes past a standing counterparty.
        while (b.fills < b.maxFills) {
            uint256 before = b.fills + b.pops;
            _matchSide(Side.SELL, b);
            _matchSide(Side.BUY, b);
            _matchBook(b);
            if (b.fills + b.pops == before) break;
        }
    }

    /// @dev Fill the book directly against itself while it is crossed.
    ///
    /// Execution price is the midpoint of the two limits, so the crossing
    /// spread is split evenly between them: the seller clears above its ask,
    /// the buyer pays below its bid, and neither outcome turns on which side
    /// arrived first. Both end up inside their own limits by construction, and
    /// neither pays a pool fee.
    ///
    /// Dead and expired heads are `_matchSide`'s job: it pops them, and the
    /// next pass of `_match` picks up here again.
    function _matchBook(Budget memory b) internal {
        while (b.fills < b.maxFills) {
            uint256 askPrice = bestAskPrice;
            uint256 bidPrice = bestBidPrice;
            if (askPrice == 0 || bidPrice == 0 || bidPrice < askPrice) break;

            Level storage askLevel = askLevels[askPrice];
            Level storage bidLevel = bidLevels[bidPrice];
            uint256 askId = askLevel.headOrder;
            uint256 bidId = bidLevel.headOrder;
            if (askId == 0 || bidId == 0) break;

            Order storage ask = orders[askId];
            Order storage bid = orders[bidId];
            if (ask.status != Status.OPEN || bid.status != Status.OPEN) break;
            if (ask.expiry <= block.timestamp || bid.expiry <= block.timestamp) break;

            _fillPair(askLevel, bidLevel, ask, bid, askId, bidId);
            b.fills++;

            if (ask.status == Status.FILLED) {
                askLevel.headOrder = ask.nextInLevel;
                if (askLevel.headOrder == 0) askLevel.tailOrder = 0;
                if (askLevel.totalBase == 0) _unlinkLevel(Side.SELL, askPrice);
            }
            if (bid.status == Status.FILLED) {
                bidLevel.headOrder = bid.nextInLevel;
                if (bidLevel.headOrder == 0) bidLevel.tailOrder = 0;
                if (bidLevel.totalBase == 0) _unlinkLevel(Side.BUY, bidPrice);
            }
        }
    }

    /// @dev One direct fill between a crossed ask and bid. Both sides' escrow
    /// is already held by this contract, so the fill is two payments and no
    /// external call — `OrderFilled` carries this contract's own address in
    /// place of a pool to mark it.
    ///
    /// Always makes progress: either a fill, or a dust remainder closed. A
    /// remainder worth less than one quote unit at the midpoint can neither
    /// be filled (its base would go for nothing) nor be left at the head of
    /// a crossed book, where it used to stop every order behind it until its
    /// maker chose to cancel.
    function _fillPair(
        Level storage askLevel,
        Level storage bidLevel,
        Order storage ask,
        Order storage bid,
        uint256 askId,
        uint256 bidId
    ) internal {
        // Floor division keeps the midpoint inside both limits (a <= (a+b)/2 <= b).
        uint256 execPrice = (ask.priceX36 + bid.priceX36) / 2;

        uint256 q = Math.min(
            ask.escrowRemaining,
            Math.min(bid.amountBase - bid.filledBase, Math.mulDiv(bid.escrowRemaining, PRICE_SCALE, execPrice))
        );
        uint256 quoteAmt = Math.mulDiv(q, execPrice, PRICE_SCALE);
        if (quoteAmt == 0) {
            // Whichever side bounds q is the dust one.
            if (q != 0 && q == ask.escrowRemaining) _closeDust(askLevel, ask, askId);
            else _closeDust(bidLevel, bid, bidId);
            return;
        }

        ask.escrowRemaining -= q;
        ask.filledBase += q;
        askLevel.totalBase -= q;

        bid.escrowRemaining -= quoteAmt;
        bid.filledBase += q;
        bidLevel.totalBase -= q;

        _pay(base, bid.maker, q);
        _pay(quote, ask.maker, quoteAmt);
        emit OrderFilled(askId, address(this), q, quoteAmt);
        emit OrderFilled(bidId, address(this), q, quoteAmt);

        if (ask.escrowRemaining == 0) {
            ask.status = Status.FILLED;
            emit OrderClosed(askId, Status.FILLED, 0);
        }
        if (bid.filledBase >= bid.amountBase || bid.escrowRemaining == 0) {
            uint256 leftoverBase = bid.amountBase - bid.filledBase;
            if (leftoverBase > 0) bidLevel.totalBase -= leftoverBase;
            bid.status = Status.FILLED;
            uint256 refund = bid.escrowRemaining;
            bid.escrowRemaining = 0;
            _pay(quote, bid.maker, refund);
            emit OrderClosed(bidId, Status.FILLED, refund);
        }
    }

    /// @dev What a crossed book would fill at right now, or 0 when it is not
    /// crossed. Both sides' pool routing stops here: past this point the book
    /// is the better source, for whichever side is looking.
    function _crossMidpoint() internal view returns (uint256) {
        uint256 ask = bestAskPrice;
        uint256 bid = bestBidPrice;
        if (ask == 0 || bid == 0 || bid < ask) return 0;
        return (ask + bid) / 2;
    }

    /// @dev Price a pool fill for this ask has to beat: its own limit, or the
    /// crossing midpoint when the book is crossed. Selling into a pool for
    /// less than the book would already pay gives the maker's base away cheap.
    function _sellTarget(uint256 orderPrice) internal view returns (uint256) {
        uint256 mid = _crossMidpoint();
        return mid > orderPrice ? mid : orderPrice;
    }

    /// @dev Mirror of `_sellTarget`: buying from a pool above the midpoint
    /// would overpay for base the book already offers cheaper.
    function _buyTarget(uint256 orderPrice) internal view returns (uint256) {
        uint256 mid = _crossMidpoint();
        return (mid != 0 && mid < orderPrice) ? mid : orderPrice;
    }

    function _matchSide(Side side, Budget memory b) internal {
        while (b.fills < b.maxFills) {
            uint256 price = side == Side.SELL ? bestAskPrice : bestBidPrice;
            if (price == 0) break;
            Level storage level = side == Side.SELL ? askLevels[price] : bidLevels[price];

            uint256 orderId = level.headOrder;
            if (orderId == 0) {
                _unlinkLevel(side, price);
                continue;
            }
            Order storage order = orders[orderId];
            if (order.status != Status.OPEN || order.expiry <= block.timestamp) {
                // Lazily cancelled/closed or expired node: pop and keep
                // going, out of the pop budget. Uncharged, stuffing a level
                // with cancelled orders behind one live order would make
                // every later match walk all of them; past ~30k nodes no
                // single call could finish, and the level — plus every worse
                // level on that side — would freeze for good. When the pops
                // run out this side stops here; the other side and the book
                // still get their fills.
                if (b.pops >= b.maxPops) break;
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (order.status == Status.OPEN) _close(orderId, order, Status.EXPIRED);
                b.pops++;
                continue;
            }
            if (_isDust(order)) {
                // A head too small to produce a nonzero fill would otherwise
                // read below as "no pool crossable here" and stop the side.
                _closeDust(level, order, orderId);
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (level.totalBase == 0) _unlinkLevel(side, price);
                b.fills++;
                continue;
            }

            (bool filledSomething, uint256 hopsUsed, bool tooSmall) =
                _fillAcrossPools(level, order, orderId, b.maxFills - b.fills);
            b.fills += hopsUsed;
            if (tooSmall && order.status == Status.OPEN) {
                // A pool has room at this price but the remainder is too
                // small to clear its limit there: the pool's rounding costs
                // it more than the price leaves over. Read as "nothing
                // crossable", it would stop every order behind it — and a
                // marketable order left resting is the sandwich placement
                // matching prevents.
                _closeDust(level, order, orderId);
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (level.totalBase == 0) _unlinkLevel(side, price);
                b.fills++;
                continue;
            }
            if (!filledSomething) break; // no pool crossable at this level => worse levels aren't either
            if (order.status == Status.FILLED) {
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (level.totalBase == 0) _unlinkLevel(side, price);
            }
        }
    }

    /// @dev Fills one order against as many spot pools as it takes (up to
    /// `hopBudget`), always picking whichever crossable pool currently has
    /// the most room before its own post-fee marginal price reaches the
    /// order's limit — spreading a large order's price impact across pools
    /// instead of dumping it into one. Stops when the order is fully filled,
    /// no pool is crossable anymore, or the hop budget runs out.
    function _fillAcrossPools(Level storage level, Order storage order, uint256 orderId, uint256 hopBudget)
        internal
        returns (bool filledSomething, uint256 hopsUsed, bool tooSmall)
    {
        while (hopsUsed < hopBudget && order.status == Status.OPEN) {
            Hop hop =
                order.side == Side.SELL ? _fillBestSell(level, order, orderId) : _fillBestBuy(level, order, orderId);
            if (hop != Hop.FILLED) {
                tooSmall = hop == Hop.TOO_SMALL;
                break;
            }
            hopsUsed++;
            filledSomething = true;
        }
    }

    function _fillBestSell(Level storage level, Order storage order, uint256 orderId) internal returns (Hop) {
        uint256 price = _sellTarget(order.priceX36);
        (address pool, uint256 dxMax, uint256 g, uint256 reserveBase, uint256 reserveQuote) = _bestPool(true, price);
        if (pool == address(0)) return Hop.NOT_CROSSABLE;
        (uint256 dx, uint256 minOut) =
            _clearLimit(Math.min(dxMax, order.escrowRemaining), true, price, reserveBase, reserveQuote, g);
        if (dx == 0) return _tooSmall(order.escrowRemaining, price) ? Hop.TOO_SMALL : Hop.NOT_CROSSABLE;

        (bool ok, uint256 spent, uint256 quoteOut) = _poolSwap(pool, base, quote, dx, minOut);
        if (!ok) return Hop.NOT_CROSSABLE;

        order.escrowRemaining -= spent;
        order.filledBase += spent;
        level.totalBase -= spent;
        _pay(quote, order.maker, quoteOut);
        emit OrderFilled(orderId, pool, spent, quoteOut);
        if (order.escrowRemaining == 0) {
            order.status = Status.FILLED;
            emit OrderClosed(orderId, Status.FILLED, 0);
        }
        return Hop.FILLED;
    }

    function _fillBestBuy(Level storage level, Order storage order, uint256 orderId) internal returns (Hop) {
        uint256 price = _buyTarget(order.priceX36);
        (address pool, uint256 dqMax, uint256 g, uint256 reserveBase, uint256 reserveQuote) = _bestPool(false, price);
        if (pool == address(0)) return Hop.NOT_CROSSABLE;

        uint256 remainingBase = order.amountBase - order.filledBase;
        uint256 dq = Math.min(dqMax, order.escrowRemaining);
        // Spend needed to buy the full remainder outright (getAmountIn).
        if (remainingBase < reserveBase) {
            uint256 effInFull =
                Math.mulDiv(reserveQuote, remainingBase, reserveBase - remainingBase, Math.Rounding.Ceil);
            uint256 dqFull = Math.mulDiv(effInFull, PPM, g, Math.Rounding.Ceil);
            dq = Math.min(dq, dqFull);
        }
        uint256 minBaseOut;
        (dq, minBaseOut) = _clearLimit(dq, false, price, reserveQuote, reserveBase, g);
        if (dq == 0) return _tooSmall(remainingBase, price) ? Hop.TOO_SMALL : Hop.NOT_CROSSABLE;

        (bool ok, uint256 spent, uint256 baseOut) = _poolSwap(pool, quote, base, dq, minBaseOut);
        if (!ok) return Hop.NOT_CROSSABLE;

        order.escrowRemaining -= spent;
        uint256 counted = Math.min(baseOut, remainingBase);
        order.filledBase += counted;
        level.totalBase -= counted;
        _pay(base, order.maker, baseOut);
        emit OrderFilled(orderId, pool, baseOut, spent);
        if (order.filledBase >= order.amountBase || order.escrowRemaining == 0) {
            uint256 leftoverBase = order.amountBase - order.filledBase;
            if (leftoverBase > 0) level.totalBase -= leftoverBase;
            order.status = Status.FILLED;
            uint256 refund = order.escrowRemaining;
            order.escrowRemaining = 0;
            _pay(quote, order.maker, refund);
            emit OrderClosed(orderId, Status.FILLED, refund);
        }
        return Hop.FILLED;
    }

    /// @dev Among every spot pool of this pair, the one with the most room
    /// before its *average* post-fee fill price reaches `price`, measured in
    /// the input token (base for a sell, quote for a buy).
    ///
    /// Selling dx base into (Rb, Rq) at fee multiplier g nets
    /// `Rq·g·dx / (Rb·PPM + g·dx)`; holding the average `out/dx` at the
    /// limit gives `dx <= Rq·1e36/price − Rb·PPM/g`. Buying with dq quote,
    /// the same rearrangement gives `dq <= Rb·price/1e36 − Rq·PPM/g`. Both
    /// terms are computed with 512-bit intermediates and rounded toward less
    /// room, so no reserve or price an order can carry overflows here.
    /// Returns the winner's fee and reserves so the caller need not re-read
    /// them.
    function _bestPool(bool sell, uint256 price)
        internal
        view
        returns (address bestPool, uint256 bestRoom, uint256 bestG, uint256 bestBase, uint256 bestQuote)
    {
        uint256 n = spotPools.length;
        for (uint256 i = 0; i < n; i++) {
            address p = spotPools[i];
            (uint256 g, uint256 reserveBase, uint256 reserveQuote) = _poolFeeAndReserves(p);
            if (reserveBase == 0 || reserveQuote == 0) continue;
            uint256 cap =
                sell ? Math.mulDiv(reserveQuote, PRICE_SCALE, price) : Math.mulDiv(reserveBase, price, PRICE_SCALE);
            uint256 floorTerm = Math.mulDiv(sell ? reserveBase : reserveQuote, PPM, g, Math.Rounding.Ceil);
            if (cap <= floorTerm) continue;
            uint256 room = cap - floorTerm;
            if (room > bestRoom) {
                bestRoom = room;
                bestPool = p;
                bestG = g;
                bestBase = reserveBase;
                bestQuote = reserveQuote;
            }
        }
    }

    function _poolFeeAndReserves(address pool)
        internal
        view
        returns (uint256 g, uint256 reserveBase, uint256 reserveQuote)
    {
        ISpotPool spot = ISpotPool(pool);
        g = PPM - spot.lpFeeRatePpm();
        (reserveBase, reserveQuote,) = spot.getReserves();
    }

    /// @dev Swap one hop against a pool, or report that it could not be done.
    function _poolSwap(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (bool ok, uint256 spent, uint256 received)
    {
        try this.executePoolSwap(pool, tokenIn, tokenOut, amountIn, minOut) returns (uint256 s, uint256 r) {
            return (true, s, r);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @notice Internal plumbing, callable only by this contract itself: one
    /// pool hop, checked against this contract's own balances. It is external
    /// only so that a hop which fails can be caught and rolled back on its
    /// own — a pool that cannot fill, or a fee-on-transfer token delivering
    /// less than the pool sent, then ends the walk instead of reverting every
    /// other order's match with it.
    ///
    /// The pool's word is not trusted for anything that moves escrow: what
    /// left and what arrived are measured here, the approval is cleared
    /// after, and a hop that took more than it was approved for, took
    /// nothing, or paid less than the order's limit allows is undone.
    function executePoolSwap(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 spent, uint256 received)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(pool, amountIn);
        ISpotPool(pool).swapFromPair(tokenIn, amountIn, minOut, address(this));
        IERC20(tokenIn).forceApprove(pool, 0);
        spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (spent == 0 || spent > amountIn || received < minOut) revert PoolMisbehaved();
    }

    // ------------------------------------------------------------- internals

    /// @dev Exactly what `SpotPool.getAmountOut` returns: the fee rounds up,
    /// so the input that counts is `floor(amountIn * g / PPM)`.
    function _amountOut(uint256 reserveIn, uint256 reserveOut, uint256 g, uint256 amountIn)
        internal
        pure
        returns (uint256)
    {
        uint256 effIn = Math.mulDiv(amountIn, g, PPM);
        return Math.mulDiv(reserveOut, effIn, reserveIn + effIn);
    }

    /// @dev Largest input of a few candidates at or below `amountIn` whose
    /// exact pool output clears the limit, with that output as the bound.
    /// The room formula is continuous; the pool rounds its effective input
    /// and its output down, so a hop sized to the boundary can come out a
    /// few units short of it. Each retry backs further off the boundary —
    /// a millionth, a ten-thousandth, then a hundredth of the hop — and a
    /// pool that still cannot clear it is left until its price moves.
    /// Returns zero when nothing clears, including a hop worth less than one
    /// unit of output.
    function _clearLimit(uint256 amountIn, bool sell, uint256 price, uint256 reserveIn, uint256 reserveOut, uint256 g)
        internal
        pure
        returns (uint256, uint256 minOut)
    {
        for (uint256 i = 0; i < 4; i++) {
            if (amountIn == 0) return (0, 0);
            minOut = sell ? Math.mulDiv(amountIn, price, PRICE_SCALE) : Math.mulDiv(amountIn, PRICE_SCALE, price);
            if (minOut == 0) return (0, 0);
            if (_amountOut(reserveIn, reserveOut, g, amountIn) >= minOut) return (amountIn, minOut);
            uint256 step = amountIn / (i == 0 ? 1e6 : i == 1 ? 1e4 : 1e2) + 2;
            amountIn = step >= amountIn ? 0 : amountIn - step;
        }
        return (0, 0);
    }

    /// @dev Whether a hop that could not clear its limit failed because the
    /// order is too small rather than because the pool sits at the limit. A
    /// remainder of `DUST_UNITS` or more on both sides of the trade clears
    /// once the pool is a couple of basis points past its limit and its own
    /// impact, so its failure means the pool is still at the limit: it waits
    /// instead of being closed. Sized by the pool's room instead, an order
    /// of any size could be closed by pushing the pool to just the right
    /// distance from its limit.
    function _tooSmall(uint256 baseAmount, uint256 price) internal pure returns (bool) {
        return baseAmount < DUST_UNITS || Math.mulDiv(baseAmount, price, PRICE_SCALE) < DUST_UNITS;
    }

    /// @dev An order too small to produce a nonzero fill at its own limit.
    function _isDust(Order storage order) internal view returns (bool) {
        uint256 price = order.priceX36;
        if (order.side == Side.SELL) return Math.mulDiv(order.escrowRemaining, price, PRICE_SCALE) == 0;
        return Math.mulDiv(order.amountBase - order.filledBase, price, PRICE_SCALE) == 0
            || Math.mulDiv(order.escrowRemaining, PRICE_SCALE, price) == 0;
    }

    /// @dev Close an order whose remainder is too small to fill. It counts as
    /// filled — it is as filled as it can get — and its escrow goes home.
    /// The caller pops it from the level.
    function _closeDust(Level storage level, Order storage order, uint256 orderId) internal {
        Side side = order.side;
        level.totalBase -= side == Side.SELL ? order.escrowRemaining : order.amountBase - order.filledBase;
        uint256 refund = order.escrowRemaining;
        order.escrowRemaining = 0;
        order.status = Status.FILLED;
        _pay(side == Side.SELL ? base : quote, order.maker, refund);
        emit OrderClosed(orderId, Status.FILLED, refund);
    }

    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Pay a maker, or hold the amount for `claim` when the transfer
    /// fails, so one maker a token refuses cannot stop matching for everyone.
    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20(token).trySafeTransfer(to, amount)) {
            claimable[to][token] += amount;
            totalClaimable[token] += amount;
            emit PaymentDeferred(to, token, amount);
        }
    }

    function _close(uint256 orderId, Order storage order, Status status) internal {
        if (order.status != Status.OPEN) revert OrderNotOpen();
        Side side = order.side;
        uint256 price = order.priceX36;
        Level storage level = side == Side.BUY ? bidLevels[price] : askLevels[price];

        uint256 remainingBase = side == Side.SELL ? order.escrowRemaining : order.amountBase - order.filledBase;
        level.totalBase -= remainingBase;
        // Node stays in the FIFO (lazy removal); matching skips non-OPEN
        // orders. An emptied level is unlinked so views stay honest.
        if (level.totalBase == 0) _unlinkLevel(side, price);

        uint256 refund = order.escrowRemaining;
        order.escrowRemaining = 0;
        order.status = status;
        _pay(side == Side.SELL ? base : quote, order.maker, refund);
        emit OrderClosed(orderId, status, refund);
    }

    function _enqueue(Side side, uint256 price, uint256 orderId, uint256 amountBase, uint256 priceHint) internal {
        Level storage level = side == Side.BUY ? bidLevels[price] : askLevels[price];
        if (!level.active) {
            _linkLevel(side, price, priceHint);
        }
        level.totalBase += amountBase;
        if (level.headOrder == 0) {
            level.headOrder = orderId;
            level.tailOrder = orderId;
        } else {
            orders[level.tailOrder].nextInLevel = orderId;
            level.tailOrder = orderId;
        }
    }

    function _isBetter(Side side, uint256 a, uint256 b) internal pure returns (bool) {
        return side == Side.BUY ? a > b : a < b;
    }

    function _linkLevel(Side side, uint256 price, uint256 priceHint) internal {
        mapping(uint256 => Level) storage book = side == Side.BUY ? bidLevels : askLevels;
        uint256 best = side == Side.BUY ? bestBidPrice : bestAskPrice;
        Level storage level = book[price];
        level.active = true;

        if (best == 0) {
            _setBest(side, price);
            return;
        }
        // Start from the hint when it is an active level at-or-better than the
        // new price; otherwise walk from the best.
        uint256 cursor = best;
        if (priceHint != 0 && book[priceHint].active && !_isBetter(side, price, priceHint)) {
            cursor = priceHint;
        }
        if (_isBetter(side, price, cursor)) {
            // Better than the walk start (only possible when cursor == best).
            level.nextPrice = cursor;
            book[cursor].prevPrice = price;
            _setBest(side, price);
            return;
        }
        // Walk toward worse prices until the next level is worse than ours.
        while (true) {
            uint256 next = book[cursor].nextPrice;
            if (next == 0 || _isBetter(side, price, next)) {
                level.prevPrice = cursor;
                level.nextPrice = next;
                book[cursor].nextPrice = price;
                if (next != 0) book[next].prevPrice = price;
                return;
            }
            cursor = next;
        }
    }

    function _unlinkLevel(Side side, uint256 price) internal {
        mapping(uint256 => Level) storage book = side == Side.BUY ? bidLevels : askLevels;
        Level storage level = book[price];
        uint256 prev = level.prevPrice;
        uint256 next = level.nextPrice;
        if (prev != 0) book[prev].nextPrice = next;
        if (next != 0) book[next].prevPrice = prev;
        uint256 best = side == Side.BUY ? bestBidPrice : bestAskPrice;
        if (best == price) _setBest(side, next);
        delete book[price];
    }

    function _setBest(Side side, uint256 price) internal {
        if (side == Side.BUY) bestBidPrice = price;
        else bestAskPrice = price;
    }
}
