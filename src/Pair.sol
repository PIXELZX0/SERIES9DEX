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
/// per-pair book: pool creation, the on-chain orderbook, and per-pair config
/// (tickSize, fixed forever by whoever creates the first spot pool). This
/// contract's own address is the pair's identifier — there is no separate
/// bytes32 pairId anymore.
///
/// Matching routes across every spot pool of this pair (`spotPools`), not a
/// single pool: each fill greedily picks whichever pool currently offers the
/// order's maker the most room before its post-fee marginal price reaches the
/// limit, so a large order spreads its price impact across pools instead of
/// dumping into one. `maxFills` now bounds pool-hops, not order-processing
/// steps — a single order filled across three pools spends three fills.
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

    uint32 public constant MAX_LEVERAGE_CAP = 50;
    uint32 public constant MIN_MAINTENANCE_MARGIN_BPS = 100;
    uint32 public constant MAX_MAINTENANCE_MARGIN_BPS = 2000;
    uint32 public constant MAX_LIQUIDATION_FEE_BPS = 500;
    uint64 public constant MAX_FUNDING_COEFF_PPM_PER_HOUR = 10_000;

    // Protocol-wide fee-rate bounds, both spot and perp: no governance knob,
    // same hardcoded range every pair gets.
    uint32 public constant MIN_LP_FEE_PPM = 1;
    uint32 public constant MAX_LP_FEE_PPM = 10_000;

    // ponytail: hard cap on spot pools, matching-loop gas scales with this
    uint256 public constant MAX_SPOT_POOLS = 8;

    address public immutable registry;
    address public immutable base; // token0, sorted
    address public immutable quote; // token1
    // Not immutable: unset (0) until the first createSpotPool call, which
    // fixes it forever — mirrors the pre-Pair design where the first spot
    // pool's creator set the tick. Keeping this decoupled from Pair's own
    // (permissionless, parameter-free) CREATE2 creation means front-running
    // createPair itself no longer lets an attacker squat a bad tick with a
    // zero-liquidity, zero-cost call before anyone has created a real pool.
    uint256 public tickSize;

    address[] public spotPools;
    address[] public perpPools;
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

    error ZeroAmount();
    error ZeroAddress();
    error InvalidTickSize();
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
    error TickSizeNotSet();
    error TooManySpotPools();

    event SpotPoolCreated(address indexed pool, address indexed creator, uint32 lpFeeRatePpm);
    event PerpPoolCreated(address indexed pool, address indexed creator, address quoteToken, uint32 lpFeeRatePpm);
    event OrderPlaced(
        uint256 indexed orderId, address indexed maker, Side side, uint256 priceX18, uint256 amountBase, uint256 escrowed, uint64 expiry
    );
    event OrderFilled(uint256 indexed orderId, address indexed pool, uint256 baseFilled, uint256 quoteAmount);
    event OrderClosed(uint256 indexed orderId, Status status, uint256 refunded);

    constructor(address registry_, address token0_, address token1_) {
        registry = registry_;
        base = token0_;
        quote = token1_;
    }

    // ---------------------------------------------------------- pool creation

    /// @notice The first call for a pair fixes `tickSize` forever (`tickSize_`
    /// must be non-zero); every later call ignores its own `tickSize_` and
    /// keeps the one already set — same rule the pre-Pair design applied to
    /// the first spot pool created for a pairId.
    function createSpotPool(uint32 lpFeeRatePpm, uint256 tickSize_) external returns (address pool) {
        if (spotPools.length >= MAX_SPOT_POOLS) revert TooManySpotPools();
        if (tickSize == 0) {
            if (tickSize_ == 0) revert InvalidTickSize();
            tickSize = tickSize_;
        }
        if (lpFeeRatePpm < MIN_LP_FEE_PPM || lpFeeRatePpm > MAX_LP_FEE_PPM) revert InvalidFeeRate();
        if (spotFeeUsed[lpFeeRatePpm]) revert DuplicateFeeRate();
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

        address factory = IDexRegistry(registry).perpPoolFactory();
        if (factory == address(0)) revert FactoryNotSet();
        address baseToken = quoteToken == base ? quote : base;
        pool = IPerpPoolFactory(factory).deploy(
            IDexRegistry(registry).treasury(), spotPool, baseToken, quoteToken, lpFeeRatePpm, params
        );
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

    function levelOf(Side side, uint256 priceX18) external view returns (bool active, uint256 totalBase, uint256 nextPrice) {
        Level storage level = side == Side.BUY ? bidLevels[priceX18] : askLevels[priceX18];
        return (level.active, level.totalBase, level.nextPrice);
    }

    // --------------------------------------------------------------- orders

    function placeOrder(Side side, uint256 priceX18, uint256 amountBase, uint64 expiry, uint256 priceHint)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (tickSize == 0) revert TickSizeNotSet();
        if (priceX18 == 0 || priceX18 % tickSize != 0) revert InvalidPrice();
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
        while (fills < maxFills) {
            uint256 before = fills;
            fills = _matchSide(Side.SELL, fills, maxFills);
            fills = _matchSide(Side.BUY, fills, maxFills);
            if (fills == before) break;
        }
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
                // Lazily cancelled/closed node: pop and keep going.
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
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
            bool ok = order.side == Side.SELL
                ? _fillBestSell(level, order, orderId)
                : _fillBestBuy(level, order, orderId);
            if (!ok) break;
            hopsUsed++;
            filledSomething = true;
        }
    }

    function _fillBestSell(Level storage level, Order storage order, uint256 orderId) internal returns (bool) {
        uint256 price = order.priceX18;
        (address pool, uint256 dxMax) = _bestSellPool(price);
        if (pool == address(0)) return false;
        uint256 dx = Math.min(dxMax, order.escrowRemaining);
        if (dx == 0) return false;

        (uint256 g, uint256 reserveBase, uint256 reserveQuote) = _poolFeeAndReserves(pool);
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
        uint256 price = order.priceX18;
        (address pool, uint256 dqMax) = _bestBuyPool(price);
        if (pool == address(0)) return false;

        (uint256 g, uint256 reserveBase, uint256 reserveQuote) = _poolFeeAndReserves(pool);
        uint256 remainingBase = order.amountBase - order.filledBase;
        uint256 dq = Math.min(dqMax, order.escrowRemaining);
        // Spend needed to buy the full remainder outright (getAmountIn).
        if (remainingBase < reserveBase) {
            uint256 effInFull = Math.mulDiv(reserveQuote, remainingBase, reserveBase - remainingBase, Math.Rounding.Ceil);
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

    /// @dev Among every spot pool of this pair, the one whose current
    /// post-fee marginal SELL price is above `price` and has the most base
    /// capacity before that marginal price would reach `price`. Both
    /// crossability and capacity reuse the same lhs/rhs derivation the
    /// single-pool version used.
    function _bestSellPool(uint256 price) internal view returns (address bestPool, uint256 bestDxMax) {
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
            }
        }
    }

    /// @dev Same idea as `_bestSellPool` for the BUY side.
    function _bestBuyPool(uint256 price) internal view returns (address bestPool, uint256 bestDqMax) {
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
            }
        }
    }

    function _poolFeeAndReserves(address pool) internal view returns (uint256 g, uint256 reserveBase, uint256 reserveQuote) {
        ISpotPool spot = ISpotPool(pool);
        g = PPM - spot.lpFeeRatePpm();
        (reserveBase, reserveQuote,) = spot.getReserves();
    }

    // ------------------------------------------------------------- internals

    function _sellOut(uint256 reserveBase, uint256 reserveQuote, uint256 g, uint256 dx) internal pure returns (uint256) {
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
        mapping(uint256 => Level) storage levels = side == Side.BUY ? bidLevels : askLevels;
        uint256 best = side == Side.BUY ? bestBidPrice : bestAskPrice;
        Level storage level = levels[price];
        level.active = true;

        if (best == 0) {
            _setBest(side, price);
            return;
        }
        // Start from the hint when it is an active level at-or-better than the
        // new price; otherwise walk from the best.
        uint256 cursor = best;
        if (priceHint != 0 && levels[priceHint].active && !_isBetter(side, price, priceHint)) {
            cursor = priceHint;
        }
        if (_isBetter(side, price, cursor)) {
            // Better than the walk start (only possible when cursor == best).
            level.nextPrice = cursor;
            levels[cursor].prevPrice = price;
            _setBest(side, price);
            return;
        }
        // Walk toward worse prices until the next level is worse than ours.
        while (true) {
            uint256 next = levels[cursor].nextPrice;
            if (next == 0 || _isBetter(side, price, next)) {
                level.prevPrice = cursor;
                level.nextPrice = next;
                levels[cursor].nextPrice = price;
                if (next != 0) levels[next].prevPrice = price;
                return;
            }
            cursor = next;
        }
    }

    function _unlinkLevel(Side side, uint256 price) internal {
        mapping(uint256 => Level) storage levels = side == Side.BUY ? bidLevels : askLevels;
        Level storage level = levels[price];
        uint256 prev = level.prevPrice;
        uint256 next = level.nextPrice;
        if (prev != 0) levels[prev].nextPrice = next;
        if (next != 0) levels[next].prevPrice = prev;
        uint256 best = side == Side.BUY ? bestBidPrice : bestAskPrice;
        if (best == price) _setBest(side, next);
        delete levels[price];
    }

    function _setBest(Side side, uint256 price) internal {
        if (side == Side.BUY) bestBidPrice = price;
        else bestAskPrice = price;
    }
}
