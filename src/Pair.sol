// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {IPerpPool, PerpParams} from "./interfaces/IPerpPool.sol";
import {IPair} from "./interfaces/IPair.sol";

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
/// `DexRegistry.createPair`. Owns everything that used to be split across
/// `DexRegistry`'s pairId-keyed mappings and the `Orderbook` singleton's
/// per-pair book: pool creation and the on-chain orderbook. This contract's
/// own address is the pair's identifier — there is no separate bytes32
/// pairId anymore, and no per-pair parameter either: order prices sit on a
/// decimal grid (`MAX_PRICE_SIG_DIGITS`) that is a pure function of the price
/// rather than a tick some first caller gets to fix forever.
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
/// resting order's price, paying no pool fee. Together the two rules mean an
/// order never routes past a counterparty that is offering better, and never
/// takes the book when a pool is cheaper.
///
/// `maxFills` bounds pool-hops, direct fills and dead-node cleanup, not
/// orders — a single order filled across three pools spends three fills.
contract Pair is IPair, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Order {
        address maker;
        Side side;
        Status status;
        uint64 expiry;
        uint256 priceX18;
        uint256 amountBase; // SELL: credited escrow (fee-on-transfer aware); BUY: nominal target
        uint256 filledBase;
        uint256 escrowRemaining; // SELL: base left to sell; BUY: quote left to spend
        uint256 nextInLevel; // FIFO link
    }

    struct Level {
        bool active;
        uint256 totalBase; // advisory sum of open remainders (may include expired-not-yet-removed)
        uint256 headOrder;
        uint256 tailOrder;
        uint256 prevPrice; // toward best
        uint256 nextPrice; // toward worse
    }

    uint256 public constant MIN_QUOTE_NOTIONAL = 1e4;
    uint256 internal constant PPM = 1e6;
    uint256 internal constant BPS = 1e4;

    uint32 public constant MAX_LEVERAGE_CAP = 50;
    uint32 public constant MIN_MAINTENANCE_MARGIN_BPS = 100;
    uint32 public constant MAX_MAINTENANCE_MARGIN_BPS = 2000;
    uint32 public constant MAX_LIQUIDATION_FEE_BPS = 500;
    uint64 public constant MAX_FUNDING_COEFF_PPM_PER_HOUR = 10_000;

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
    /// `priceX18` may carry at most this many significant decimal digits.
    /// The granularity is relative, so a pair priced at 1e21 (WBTC/USDC) and
    /// one priced at 1e1 (SHIB/USDC) both get ~6 usable digits — something no
    /// absolute tick constant can do. And because it is a pure function of
    /// the price, there is no per-pair value for a first caller to squat.
    uint256 public constant MAX_PRICE_SIG_DIGITS = 6;

    address public immutable registry;
    address public immutable base; // token0, sorted
    address public immutable quote; // token1

    address[] public spotPools;
    address[] public perpPools;
    uint256 public customSpotPools; // spotPools created off the canonical tiers
    mapping(address => bool) public isSpotPool;
    mapping(uint32 => bool) public spotFeeUsed;
    // Perp markets vary by quoteToken too (base/quote roles flip), so the
    // same fee is fine on two perp pools quoted in different tokens — only
    // dedup within a given quoteToken.
    mapping(address => mapping(uint32 => bool)) public perpFeeUsed;

    uint256 public bestBidPrice; // highest bid, 0 = empty
    uint256 public bestAskPrice; // lowest ask, 0 = empty
    mapping(uint256 => Level) internal bidLevels;
    mapping(uint256 => Level) internal askLevels;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;
    mapping(address => uint256[]) internal _makerOrders;

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
    error InvalidFeeRate();
    error DuplicateFeeRate();
    error FactoryNotSet();
    error InvalidQuoteToken();
    error UnknownSpotPool();
    error InvalidPerpParams();
    error TooManyCustomSpotPools();

    event SpotPoolCreated(address indexed pool, address indexed creator, uint32 lpFeeRatePpm);
    event PerpPoolCreated(address indexed pool, address indexed creator, address quoteToken, uint32 lpFeeRatePpm);
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        uint256 priceX18,
        uint256 amountBase,
        uint256 escrowed,
        uint64 expiry
    );
    event OrderFilled(uint256 indexed orderId, address indexed pool, uint256 baseFilled, uint256 quoteAmount);
    event OrderClosed(uint256 indexed orderId, Status status, uint256 refunded);

    constructor(address registry_, address token0_, address token1_) {
        registry = registry_;
        base = token0_;
        quote = token1_;
    }

    // ---------------------------------------------------------- pool creation

    /// @notice One spot pool per fee rate. The four canonical tiers are
    /// always available; every other rate consumes one of the twelve custom
    /// slots. Carries no per-pair parameter, so there is nothing to squat.
    function createSpotPool(uint32 lpFeeRatePpm) external returns (address pool) {
        if (lpFeeRatePpm < MIN_LP_FEE_PPM || lpFeeRatePpm > MAX_LP_FEE_PPM) revert InvalidFeeRate();
        if (spotFeeUsed[lpFeeRatePpm]) revert DuplicateFeeRate();
        if (!isCanonicalFeeTier(lpFeeRatePpm)) {
            if (customSpotPools >= MAX_CUSTOM_SPOT_POOLS) revert TooManyCustomSpotPools();
            customSpotPools++;
        }
        address factory = IDexRegistry(registry).spotPoolFactory();
        if (factory == address(0)) revert FactoryNotSet();
        pool = ISpotPoolFactory(factory).deploy(IDexRegistry(registry).treasury(), base, quote, lpFeeRatePpm);
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
        if (lpFeeRatePpm < MIN_LP_FEE_PPM || lpFeeRatePpm > MAX_LP_FEE_PPM) revert InvalidFeeRate();
        if (quoteToken != base && quoteToken != quote) revert InvalidQuoteToken();
        if (!isSpotPool[spotPool]) revert UnknownSpotPool();
        if (perpFeeUsed[quoteToken][lpFeeRatePpm]) revert DuplicateFeeRate();
        if (
            params.maxLeverageX == 0 || params.maxLeverageX > MAX_LEVERAGE_CAP
                || params.maintenanceMarginBps < MIN_MAINTENANCE_MARGIN_BPS
                || params.maintenanceMarginBps > MAX_MAINTENANCE_MARGIN_BPS
                || params.liquidationFeeBps > MAX_LIQUIDATION_FEE_BPS || params.maxUtilizationBps == 0
                || params.maxUtilizationBps > 10_000 || params.fundingCoeffPpmPerHour > MAX_FUNDING_COEFF_PPM_PER_HOUR
        ) revert InvalidPerpParams();
        // Initial margin at the pool's own max leverage has to clear
        // maintenance plus the liquidation fee. Without this the two bounds
        // pass independently while combining into a pool where a max-leverage
        // position is liquidatable the block it opens (50x = 200bps initial
        // margin against a 2000bps maintenance floor).
        if (BPS / params.maxLeverageX <= uint256(params.maintenanceMarginBps) + params.liquidationFeeBps) {
            revert InvalidPerpParams();
        }

        address factory = IDexRegistry(registry).perpPoolFactory();
        if (factory == address(0)) revert FactoryNotSet();
        address baseToken = quoteToken == base ? quote : base;
        pool = IPerpPoolFactory(factory)
            .deploy(IDexRegistry(registry).treasury(), spotPool, baseToken, quoteToken, lpFeeRatePpm, params);
        perpPools.push(pool);
        perpFeeUsed[quoteToken][lpFeeRatePpm] = true;
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

    function bestBid() external view returns (uint256 priceX18, uint256 totalBase) {
        priceX18 = bestBidPrice;
        totalBase = priceX18 == 0 ? 0 : bidLevels[priceX18].totalBase;
    }

    function bestAsk() external view returns (uint256 priceX18, uint256 totalBase) {
        priceX18 = bestAskPrice;
        totalBase = priceX18 == 0 ? 0 : askLevels[priceX18].totalBase;
    }

    function levelOf(Side side, uint256 priceX18)
        external
        view
        returns (bool active, uint256 totalBase, uint256 nextPrice)
    {
        Level storage level = side == Side.BUY ? bidLevels[priceX18] : askLevels[priceX18];
        return (level.active, level.totalBase, level.nextPrice);
    }

    /// @notice Walk one side of the book outward from `startPrice` (0 starts
    /// at the best price). `cursor` is what to pass as the next call's
    /// `startPrice`; 0 means the side is exhausted.
    function levels(Side side, uint256 startPrice, uint256 count)
        external
        view
        returns (uint256[] memory prices, uint256[] memory totalBase, uint256 cursor)
    {
        mapping(uint256 => Level) storage book = side == Side.BUY ? bidLevels : askLevels;
        cursor = startPrice == 0 ? (side == Side.BUY ? bestBidPrice : bestAskPrice) : startPrice;
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

    /// @notice A page of one maker's orders, oldest first. `start` indexes
    /// that maker's own list, not `orders`. Includes closed orders — the FIFO
    /// keeps them and so does this, so a front end can show fill history
    /// without replaying events.
    function ordersOf(address maker, uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory ids, Order[] memory page)
    {
        uint256[] storage all = _makerOrders[maker];
        uint256 len = all.length;
        if (start >= len) return (new uint256[](0), new Order[](0));
        uint256 n = Math.min(count, len - start);
        ids = new uint256[](n);
        page = new Order[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = all[start + i];
            page[i] = orders[ids[i]];
        }
    }

    function isCanonicalFeeTier(uint32 lpFeeRatePpm) public pure returns (bool) {
        return lpFeeRatePpm == FEE_TIER_LOWEST || lpFeeRatePpm == FEE_TIER_LOW || lpFeeRatePpm == FEE_TIER_MEDIUM
            || lpFeeRatePpm == FEE_TIER_HIGH;
    }

    /// @notice Whether `priceX18` sits on the decimal grid `placeOrder` accepts.
    function priceIsValid(uint256 priceX18) public pure returns (bool) {
        if (priceX18 == 0) return false;
        uint256 ceiling = 10 ** MAX_PRICE_SIG_DIGITS;
        while (priceX18 >= ceiling) {
            if (priceX18 % 10 != 0) return false;
            priceX18 /= 10;
        }
        return true;
    }

    /// @notice Smallest legal price increment at `priceX18`'s magnitude —
    /// what a per-pair `tickSize` used to be, derived rather than chosen.
    function tickSizeAt(uint256 priceX18) public pure returns (uint256 tick) {
        tick = 1;
        uint256 ceiling = 10 ** MAX_PRICE_SIG_DIGITS;
        while (priceX18 >= ceiling) {
            priceX18 /= 10;
            tick *= 10;
        }
    }

    // --------------------------------------------------------------- orders

    function placeOrder(Side side, uint256 priceX18, uint256 amountBase, uint64 expiry, uint256 priceHint)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (!priceIsValid(priceX18)) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (Math.mulDiv(amountBase, priceX18, 1e18) < MIN_QUOTE_NOTIONAL) revert NotionalTooSmall();

        uint256 escrowed;
        if (side == Side.SELL) {
            escrowed = _pull(base, amountBase);
            amountBase = escrowed; // fee-on-transfer: sellable = what actually arrived
            if (amountBase == 0) revert InvalidAmount();
        } else {
            escrowed = _pull(quote, Math.mulDiv(amountBase, priceX18, 1e18, Math.Rounding.Ceil));
        }

        orderId = nextOrderId++;
        Order storage order = orders[orderId];
        order.maker = msg.sender;
        order.side = side;
        order.status = Status.OPEN;
        order.expiry = expiry;
        order.priceX18 = priceX18;
        order.amountBase = amountBase;
        order.escrowRemaining = escrowed;
        _makerOrders[msg.sender].push(orderId);

        _enqueue(side, priceX18, orderId, amountBase, priceHint);
        emit OrderPlaced(orderId, msg.sender, side, priceX18, amountBase, escrowed, expiry);
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
        uint256 fills;
        // Asks push pools' prices down, bids push them up; a book crossed on
        // both sides may need alternating passes. Bounded by maxFills.
        //
        // Pools run first, but capped at the opposite side of the book rather
        // than at the order's own limit (`_sellTarget`/`_buyTarget`). A pool
        // is therefore only ever used while it beats the resting order on the
        // other side, and `_matchBook` takes over from the point where it
        // stops — so a fill always comes from whichever source is better at
        // the margin, and never routes past a standing counterparty.
        while (fills < maxFills) {
            uint256 before = fills;
            fills = _matchSide(Side.SELL, fills, maxFills);
            fills = _matchSide(Side.BUY, fills, maxFills);
            fills = _matchBook(fills, maxFills);
            if (fills == before) break;
        }
    }

    /// @dev Fill the book directly against itself while it is crossed.
    ///
    /// Execution price is the resting order's — the older of the two by id —
    /// which is ordinary price-time priority. Both makers end up inside their
    /// own limits by construction, and neither pays a pool fee.
    ///
    /// Dead and expired heads are `_matchSide`'s job: it pops them (charging a
    /// fill each), and the next pass of `_match` picks up here again.
    function _matchBook(uint256 fills, uint256 maxFills) internal returns (uint256) {
        while (fills < maxFills) {
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

            if (!_fillPair(askLevel, bidLevel, ask, bid, askId, bidId)) break;
            fills++;

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
        return fills;
    }

    /// @dev One direct fill between a crossed ask and bid. Both sides' escrow
    /// is already held by this contract, so the fill is two transfers and no
    /// external call — `OrderFilled` carries this contract's own address in
    /// place of a pool to mark it.
    function _fillPair(
        Level storage askLevel,
        Level storage bidLevel,
        Order storage ask,
        Order storage bid,
        uint256 askId,
        uint256 bidId
    ) internal returns (bool) {
        // The older id is the order that was resting, and the resting order
        // sets the price.
        uint256 execPrice = askId < bidId ? ask.priceX18 : bid.priceX18;

        uint256 q = Math.min(
            ask.escrowRemaining,
            Math.min(bid.amountBase - bid.filledBase, Math.mulDiv(bid.escrowRemaining, 1e18, execPrice))
        );
        if (q == 0) return false;
        uint256 quoteAmt = Math.mulDiv(q, execPrice, 1e18);
        // Dust below one quote unit would hand the ask's base over for free.
        if (quoteAmt == 0) return false;

        ask.escrowRemaining -= q;
        ask.filledBase += q;
        askLevel.totalBase -= q;

        bid.escrowRemaining -= quoteAmt;
        bid.filledBase += q;
        bidLevel.totalBase -= q;

        IERC20(base).safeTransfer(bid.maker, q);
        IERC20(quote).safeTransfer(ask.maker, quoteAmt);
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
            if (refund > 0) IERC20(quote).safeTransfer(bid.maker, refund);
            emit OrderClosed(bidId, Status.FILLED, refund);
        }
        return true;
    }

    /// @dev Price a pool fill for this ask has to beat: its own limit, or the
    /// best bid when the book is crossed. Selling into a pool below a bid that
    /// is already willing to pay more would give the maker's base away cheap.
    function _sellTarget(uint256 orderPrice) internal view returns (uint256) {
        uint256 bid = bestBidPrice;
        return bid > orderPrice ? bid : orderPrice;
    }

    /// @dev Mirror of `_sellTarget`: buying from a pool above a standing ask
    /// would overpay for base the book already offers cheaper.
    function _buyTarget(uint256 orderPrice) internal view returns (uint256) {
        uint256 ask = bestAskPrice;
        return (ask != 0 && ask < orderPrice) ? ask : orderPrice;
    }

    function _matchSide(Side side, uint256 fills, uint256 maxFills) internal returns (uint256) {
        while (fills < maxFills) {
            uint256 price = side == Side.SELL ? bestAskPrice : bestBidPrice;
            if (price == 0) break;
            Level storage level = side == Side.SELL ? askLevels[price] : bidLevels[price];

            uint256 orderId = level.headOrder;
            if (orderId == 0) {
                _unlinkLevel(side, price);
                continue;
            }
            Order storage order = orders[orderId];
            if (order.status != Status.OPEN) {
                // Lazily cancelled/closed node: pop and keep going. This
                // costs a fill. Without that, stuffing a level with cancelled
                // orders behind one live order makes every later match walk
                // all of them for free; past ~30k nodes no single call can
                // finish, every call reverts, and the level — plus every
                // worse level on that side — is frozen for good.
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                fills++;
                continue;
            }
            if (order.expiry <= block.timestamp) {
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                _close(orderId, order, Status.EXPIRED);
                fills++;
                continue;
            }

            (bool filledSomething, uint256 hopsUsed) = _fillAcrossPools(level, order, orderId, maxFills - fills);
            if (!filledSomething) break; // no pool crossable at this level => worse levels aren't either
            fills += hopsUsed;
            if (order.status == Status.FILLED) {
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (level.totalBase == 0) _unlinkLevel(side, price);
            }
        }
        return fills;
    }

    /// @dev Fills one order against as many spot pools as it takes (up to
    /// `hopBudget`), always picking whichever crossable pool currently has
    /// the most room before its own post-fee marginal price reaches the
    /// order's limit — spreading a large order's price impact across pools
    /// instead of dumping it into one. Stops when the order is fully filled,
    /// no pool is crossable anymore, or the hop budget runs out.
    function _fillAcrossPools(Level storage level, Order storage order, uint256 orderId, uint256 hopBudget)
        internal
        returns (bool filledSomething, uint256 hopsUsed)
    {
        while (hopsUsed < hopBudget && order.status == Status.OPEN) {
            bool ok =
                order.side == Side.SELL ? _fillBestSell(level, order, orderId) : _fillBestBuy(level, order, orderId);
            if (!ok) break;
            hopsUsed++;
            filledSomething = true;
        }
    }

    function _fillBestSell(Level storage level, Order storage order, uint256 orderId) internal returns (bool) {
        uint256 price = _sellTarget(order.priceX18);
        (address pool, uint256 dxMax, uint256 g, uint256 reserveBase, uint256 reserveQuote) = _bestSellPool(price);
        if (pool == address(0)) return false;
        uint256 dx = Math.min(dxMax, order.escrowRemaining);
        if (dx == 0) return false;

        uint256 minOut = Math.mulDiv(dx, price, 1e18);
        // Integer rounding can shave the AMM output below the bound;
        // shrink once, then give up on this pool until its price moves.
        if (_sellOut(reserveBase, reserveQuote, g, dx) < minOut) {
            if (dx == 1) return false;
            dx -= 1;
            minOut = Math.mulDiv(dx, price, 1e18);
            if (dx == 0 || _sellOut(reserveBase, reserveQuote, g, dx) < minOut) return false;
        }

        IERC20(base).forceApprove(pool, dx);
        uint256 quoteOut = ISpotPool(pool).swapFromPair(base, dx, minOut, order.maker);

        order.escrowRemaining -= dx;
        order.filledBase += dx;
        level.totalBase -= dx;
        emit OrderFilled(orderId, pool, dx, quoteOut);
        if (order.escrowRemaining == 0) {
            order.status = Status.FILLED;
            emit OrderClosed(orderId, Status.FILLED, 0);
        }
        return true;
    }

    function _fillBestBuy(Level storage level, Order storage order, uint256 orderId) internal returns (bool) {
        uint256 price = _buyTarget(order.priceX18);
        (address pool, uint256 dqMax, uint256 g, uint256 reserveBase, uint256 reserveQuote) = _bestBuyPool(price);
        if (pool == address(0)) return false;

        uint256 remainingBase = order.amountBase - order.filledBase;
        uint256 dq = Math.min(dqMax, order.escrowRemaining);
        // Spend needed to buy the full remainder outright (getAmountIn).
        if (remainingBase < reserveBase) {
            uint256 effInFull =
                Math.mulDiv(reserveQuote, remainingBase, reserveBase - remainingBase, Math.Rounding.Ceil);
            uint256 dqFull = Math.mulDiv(effInFull, PPM, g, Math.Rounding.Ceil);
            dq = Math.min(dq, dqFull);
        }
        if (dq == 0) return false;

        uint256 minBaseOut = Math.mulDiv(dq, 1e18, price);
        if (_buyOut(reserveBase, reserveQuote, g, dq) < minBaseOut) {
            if (dq == 1) return false;
            dq -= 1;
            minBaseOut = Math.mulDiv(dq, 1e18, price);
            if (dq == 0 || _buyOut(reserveBase, reserveQuote, g, dq) < minBaseOut) return false;
        }

        IERC20(quote).forceApprove(pool, dq);
        uint256 baseOut = ISpotPool(pool).swapFromPair(quote, dq, minBaseOut, order.maker);

        order.escrowRemaining -= dq;
        uint256 counted = Math.min(baseOut, remainingBase);
        order.filledBase += counted;
        level.totalBase -= counted;
        emit OrderFilled(orderId, pool, baseOut, dq);
        if (order.filledBase >= order.amountBase || order.escrowRemaining == 0) {
            uint256 leftoverBase = order.amountBase - order.filledBase;
            if (leftoverBase > 0) level.totalBase -= leftoverBase;
            order.status = Status.FILLED;
            uint256 refund = order.escrowRemaining;
            order.escrowRemaining = 0;
            if (refund > 0) IERC20(quote).safeTransfer(order.maker, refund);
            emit OrderClosed(orderId, Status.FILLED, refund);
        }
        return true;
    }

    /// @dev Among every spot pool of this pair, the one with the most base
    /// capacity before its average post-fee SELL price would fall to `price`.
    /// Selling dx base into (Rb, Rq) at fee multiplier g nets
    /// `Rq·g·dx / (Rb·PPM + g·dx)`; setting the average `out/dx` equal to the
    /// limit and solving for dx gives the `dxMax` below, and the same
    /// rearrangement with dx = 0 gives the crossability test. Returns the
    /// winner's fee and reserves so the caller need not re-read them.
    function _bestSellPool(uint256 price)
        internal
        view
        returns (address bestPool, uint256 bestDxMax, uint256 bestG, uint256 bestBase, uint256 bestQuote)
    {
        uint256 n = spotPools.length;
        for (uint256 i = 0; i < n; i++) {
            address p = spotPools[i];
            (uint256 g, uint256 reserveBase, uint256 reserveQuote) = _poolFeeAndReserves(p);
            if (reserveBase == 0 || reserveQuote == 0) continue;
            uint256 lhs = g * reserveQuote * 1e18;
            uint256 rhs = price * reserveBase * PPM;
            if (lhs <= rhs) continue;
            uint256 dxMax = (lhs - rhs) / (price * g);
            if (dxMax > bestDxMax) {
                bestDxMax = dxMax;
                bestPool = p;
                bestG = g;
                bestBase = reserveBase;
                bestQuote = reserveQuote;
            }
        }
    }

    /// @dev Same idea as `_bestSellPool` for the BUY side.
    function _bestBuyPool(uint256 price)
        internal
        view
        returns (address bestPool, uint256 bestDqMax, uint256 bestG, uint256 bestBase, uint256 bestQuote)
    {
        uint256 n = spotPools.length;
        for (uint256 i = 0; i < n; i++) {
            address p = spotPools[i];
            (uint256 g, uint256 reserveBase, uint256 reserveQuote) = _poolFeeAndReserves(p);
            if (reserveBase == 0 || reserveQuote == 0) continue;
            uint256 lhs = g * reserveBase * price;
            uint256 rhs = reserveQuote * PPM * 1e18;
            if (lhs <= rhs) continue;
            uint256 dqMax = (lhs - rhs) / (g * 1e18);
            if (dqMax > bestDqMax) {
                bestDqMax = dqMax;
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

    // ------------------------------------------------------------- internals

    function _sellOut(uint256 reserveBase, uint256 reserveQuote, uint256 g, uint256 dx)
        internal
        pure
        returns (uint256)
    {
        uint256 effIn = g * dx;
        return Math.mulDiv(reserveQuote, effIn, reserveBase * PPM + effIn);
    }

    function _buyOut(uint256 reserveBase, uint256 reserveQuote, uint256 g, uint256 dq) internal pure returns (uint256) {
        uint256 effIn = g * dq;
        return Math.mulDiv(reserveBase, effIn, reserveQuote * PPM + effIn);
    }

    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    function _close(uint256 orderId, Order storage order, Status status) internal {
        if (order.status != Status.OPEN) revert OrderNotOpen();
        Side side = order.side;
        uint256 price = order.priceX18;
        Level storage level = side == Side.BUY ? bidLevels[price] : askLevels[price];

        uint256 remainingBase = side == Side.SELL ? order.escrowRemaining : order.amountBase - order.filledBase;
        level.totalBase -= remainingBase;
        // Node stays in the FIFO (lazy removal); matching skips non-OPEN
        // orders. An emptied level is unlinked so views stay honest.
        if (level.totalBase == 0) _unlinkLevel(side, price);

        uint256 refund = order.escrowRemaining;
        order.escrowRemaining = 0;
        order.status = status;
        if (refund > 0) {
            IERC20(side == Side.SELL ? base : quote).safeTransfer(order.maker, refund);
        }
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
