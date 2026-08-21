// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";

/// @notice Fully on-chain orderbook (DEX.md §4.2), one singleton holding every
/// pair's book keyed by pairId. Limit orders escrow the sold token in full at
/// placement and execute against a same-pair AMM spot pool whenever the pool
/// price crosses the limit price: each fill is a pool swap whose proceeds go
/// straight to the maker at an average price no worse than the limit.
/// Matching is permissionless (`matchOrders`) and also triggered by pools
/// after user swaps (`matchFromPool`).
///
/// Price convention: base = token0 (lower address), quote = token1;
/// priceX18 = quote raw units per 1e18 base raw units, a multiple of the
/// book's tick. Bids/asks are sorted doubly-linked price-level lists with a
/// FIFO order queue per level; cancels are lazy (skipped during matching).
contract Orderbook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        BUY,
        SELL
    }

    enum Status {
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    struct Order {
        address maker;
        Side side;
        Status status;
        uint64 expiry;
        bytes32 pairId;
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

    struct Book {
        bool initialized;
        address base;
        address quote;
        uint256 tickSize;
        uint256 bestBidPrice; // highest bid, 0 = empty
        uint256 bestAskPrice; // lowest ask, 0 = empty
        mapping(uint256 => Level) bidLevels;
        mapping(uint256 => Level) askLevels;
    }

    uint256 public constant MIN_QUOTE_NOTIONAL = 1e4;
    uint256 internal constant PPM = 1e6;

    address public immutable registry;

    mapping(bytes32 => Book) internal books;
    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;

    error OnlyRegistry();
    error OnlySpotPool();
    error BookAlreadyInitialized();
    error BookNotInitialized();
    error InvalidTickSize();
    error InvalidPrice();
    error InvalidAmount();
    error InvalidExpiry();
    error NotionalTooSmall();
    error NotMaker();
    error OrderNotOpen();
    error OrderNotExpired();
    error InvalidPool();

    event BookInitialized(bytes32 indexed pairId, address indexed base, address indexed quote, uint256 tickSize);
    event OrderPlaced(
        uint256 indexed orderId,
        bytes32 indexed pairId,
        address indexed maker,
        Side side,
        uint256 priceX18,
        uint256 amountBase,
        uint256 escrowed,
        uint64 expiry
    );
    event OrderFilled(uint256 indexed orderId, address indexed pool, uint256 baseFilled, uint256 quoteAmount);
    event OrderClosed(uint256 indexed orderId, Status status, uint256 refunded);

    constructor(address registry_) {
        registry = registry_;
    }

    // ---------------------------------------------------------------- admin

    function initBook(bytes32 pairId, address base, address quote, uint256 tickSize) external {
        if (msg.sender != registry) revert OnlyRegistry();
        Book storage book = books[pairId];
        if (book.initialized) revert BookAlreadyInitialized();
        if (tickSize == 0) revert InvalidTickSize();
        book.initialized = true;
        book.base = base;
        book.quote = quote;
        book.tickSize = tickSize;
        emit BookInitialized(pairId, base, quote, tickSize);
    }

    // ---------------------------------------------------------------- views

    function bestBid(bytes32 pairId) external view returns (uint256 priceX18, uint256 totalBase) {
        Book storage book = books[pairId];
        priceX18 = book.bestBidPrice;
        totalBase = priceX18 == 0 ? 0 : book.bidLevels[priceX18].totalBase;
    }

    function bestAsk(bytes32 pairId) external view returns (uint256 priceX18, uint256 totalBase) {
        Book storage book = books[pairId];
        priceX18 = book.bestAskPrice;
        totalBase = priceX18 == 0 ? 0 : book.askLevels[priceX18].totalBase;
    }

    function bookConfig(bytes32 pairId)
        external
        view
        returns (bool initialized, address base, address quote, uint256 tickSize)
    {
        Book storage book = books[pairId];
        return (book.initialized, book.base, book.quote, book.tickSize);
    }

    function levelOf(bytes32 pairId, Side side, uint256 priceX18)
        external
        view
        returns (bool active, uint256 totalBase, uint256 nextPrice)
    {
        Book storage book = books[pairId];
        Level storage level = side == Side.BUY ? book.bidLevels[priceX18] : book.askLevels[priceX18];
        return (level.active, level.totalBase, level.nextPrice);
    }

    // --------------------------------------------------------------- orders

    function placeOrder(
        bytes32 pairId,
        Side side,
        uint256 priceX18,
        uint256 amountBase,
        uint64 expiry,
        uint256 priceHint
    ) external nonReentrant returns (uint256 orderId) {
        Book storage book = books[pairId];
        if (!book.initialized) revert BookNotInitialized();
        if (priceX18 == 0 || priceX18 % book.tickSize != 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (Math.mulDiv(amountBase, priceX18, 1e18) < MIN_QUOTE_NOTIONAL) revert NotionalTooSmall();

        uint256 escrowed;
        if (side == Side.SELL) {
            escrowed = _pull(book.base, amountBase);
            amountBase = escrowed; // fee-on-transfer: sellable = what actually arrived
            if (amountBase == 0) revert InvalidAmount();
        } else {
            escrowed = _pull(book.quote, Math.mulDiv(amountBase, priceX18, 1e18, Math.Rounding.Ceil));
        }

        orderId = nextOrderId++;
        Order storage order = orders[orderId];
        order.maker = msg.sender;
        order.side = side;
        order.status = Status.OPEN;
        order.expiry = expiry;
        order.pairId = pairId;
        order.priceX18 = priceX18;
        order.amountBase = amountBase;
        order.escrowRemaining = escrowed;

        _enqueue(book, side, priceX18, orderId, amountBase, priceHint);
        emit OrderPlaced(orderId, pairId, msg.sender, side, priceX18, amountBase, escrowed, expiry);
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

    /// @notice Permissionless keeper entry point; caller picks the pool and
    /// pays the gas.
    function matchOrders(bytes32 pairId, address pool, uint256 maxFills) external nonReentrant {
        IDexRegistry reg = IDexRegistry(registry);
        if (!reg.isSpotPool(pool) || reg.poolPairId(pool) != pairId) revert InvalidPool();
        _match(pairId, pool, maxFills);
    }

    /// @notice Called by a spot pool right after a user swap moved its price.
    function matchFromPool(bytes32 pairId, uint256 maxFills) external nonReentrant {
        IDexRegistry reg = IDexRegistry(registry);
        if (!reg.isSpotPool(msg.sender) || reg.poolPairId(msg.sender) != pairId) revert OnlySpotPool();
        _match(pairId, msg.sender, maxFills);
    }

    function _match(bytes32 pairId, address pool, uint256 maxFills) internal {
        Book storage book = books[pairId];
        if (!book.initialized) revert BookNotInitialized();
        uint256 fills;
        // Asks push the pool price down, bids push it up; a book crossed on
        // both sides may need alternating passes. Bounded by maxFills.
        while (fills < maxFills) {
            uint256 before = fills;
            fills = _matchSide(book, pool, Side.SELL, fills, maxFills);
            fills = _matchSide(book, pool, Side.BUY, fills, maxFills);
            if (fills == before) break;
        }
    }

    function _matchSide(Book storage book, address pool, Side side, uint256 fills, uint256 maxFills)
        internal
        returns (uint256)
    {
        while (fills < maxFills) {
            uint256 price = side == Side.SELL ? book.bestAskPrice : book.bestBidPrice;
            if (price == 0) break;
            Level storage level = side == Side.SELL ? book.askLevels[price] : book.bidLevels[price];

            uint256 orderId = level.headOrder;
            if (orderId == 0) {
                _unlinkLevel(book, side, price);
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

            (bool filledSomething, bool poolAtLimit) = _fillAgainstPool(book, pool, level, order, orderId);
            if (!filledSomething) break; // best level not crossable => worse levels aren't either
            fills++;
            if (order.status == Status.FILLED) {
                level.headOrder = order.nextInLevel;
                if (level.headOrder == 0) level.tailOrder = 0;
                if (level.totalBase == 0) _unlinkLevel(book, side, price);
            }
            if (poolAtLimit) break; // pool landed exactly on the limit price
        }
        return fills;
    }

    /// @dev One fill of `order` against `pool`. Returns (filledSomething,
    /// poolAtLimit). Fill size is capped so the average execution price never
    /// crosses the limit; when the cap binds, the pool has been consumed down
    /// to the limit price and matching on this side must stop.
    function _fillAgainstPool(
        Book storage book,
        address pool,
        Level storage level,
        Order storage order,
        uint256 orderId
    ) internal returns (bool, bool) {
        uint256 g;
        uint256 reserveBase;
        uint256 reserveQuote;
        {
            ISpotPool spot = ISpotPool(pool);
            g = PPM - spot.lpFeeRatePpm();
            (uint256 r0, uint256 r1,) = spot.getReserves();
            (reserveBase, reserveQuote) = (r0, r1); // base = token0 by convention
        }
        if (reserveBase == 0 || reserveQuote == 0) return (false, false);
        uint256 price = order.priceX18;

        if (order.side == Side.SELL) {
            // Crossable iff marginal pool bid (with fee) exceeds the limit.
            uint256 lhs = g * reserveQuote * 1e18;
            uint256 rhs = price * reserveBase * PPM;
            if (lhs <= rhs) return (false, false);
            uint256 dxMax = (lhs - rhs) / (price * g);
            uint256 dx = Math.min(dxMax, order.escrowRemaining);
            if (dx == 0) return (false, false);

            uint256 minOut = Math.mulDiv(dx, price, 1e18);
            // Integer rounding can shave the AMM output below the bound;
            // shrink once, then give up until the price moves.
            if (_sellOut(reserveBase, reserveQuote, g, dx) < minOut) {
                if (dx == 1) return (false, false);
                dx -= 1;
                minOut = Math.mulDiv(dx, price, 1e18);
                if (dx == 0 || _sellOut(reserveBase, reserveQuote, g, dx) < minOut) return (false, false);
            }

            IERC20(book.base).forceApprove(pool, dx);
            uint256 quoteOut = ISpotPool(pool).swapFromOrderbook(book.base, dx, minOut, order.maker);

            order.escrowRemaining -= dx;
            order.filledBase += dx;
            level.totalBase -= dx;
            emit OrderFilled(orderId, pool, dx, quoteOut);
            if (order.escrowRemaining == 0) {
                order.status = Status.FILLED;
                emit OrderClosed(orderId, Status.FILLED, 0);
            }
            return (true, dx == dxMax);
        } else {
            // BUY: crossable iff marginal pool ask (with fee) is below the limit.
            uint256 lhs = g * reserveBase * price;
            uint256 rhs = reserveQuote * PPM * 1e18;
            if (lhs <= rhs) return (false, false);
            uint256 dqMax = (lhs - rhs) / (g * 1e18);

            uint256 remainingBase = order.amountBase - order.filledBase;
            uint256 dq = Math.min(dqMax, order.escrowRemaining);
            // Spend needed to buy the full remainder outright (getAmountIn).
            if (remainingBase < reserveBase) {
                uint256 effInFull =
                    Math.mulDiv(reserveQuote, remainingBase, reserveBase - remainingBase, Math.Rounding.Ceil);
                uint256 dqFull = Math.mulDiv(effInFull, PPM, g, Math.Rounding.Ceil);
                dq = Math.min(dq, dqFull);
            }
            if (dq == 0) return (false, false);

            uint256 minBaseOut = Math.mulDiv(dq, 1e18, price);
            if (_buyOut(reserveBase, reserveQuote, g, dq) < minBaseOut) {
                if (dq == 1) return (false, false);
                dq -= 1;
                minBaseOut = Math.mulDiv(dq, 1e18, price);
                if (dq == 0 || _buyOut(reserveBase, reserveQuote, g, dq) < minBaseOut) return (false, false);
            }

            IERC20(book.quote).forceApprove(pool, dq);
            uint256 baseOut = ISpotPool(pool).swapFromOrderbook(book.quote, dq, minBaseOut, order.maker);

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
                if (refund > 0) IERC20(book.quote).safeTransfer(order.maker, refund);
                emit OrderClosed(orderId, Status.FILLED, refund);
            }
            return (true, dq == dqMax);
        }
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
        Book storage book = books[order.pairId];
        Side side = order.side;
        uint256 price = order.priceX18;
        Level storage level = side == Side.BUY ? book.bidLevels[price] : book.askLevels[price];

        uint256 remainingBase = side == Side.SELL ? order.escrowRemaining : order.amountBase - order.filledBase;
        level.totalBase -= remainingBase;
        // Node stays in the FIFO (lazy removal); matching skips non-OPEN
        // orders. An emptied level is unlinked so views stay honest.
        if (level.totalBase == 0) _unlinkLevel(book, side, price);

        uint256 refund = order.escrowRemaining;
        order.escrowRemaining = 0;
        order.status = status;
        if (refund > 0) {
            IERC20(side == Side.SELL ? book.base : book.quote).safeTransfer(order.maker, refund);
        }
        emit OrderClosed(orderId, status, refund);
    }

    function _enqueue(
        Book storage book,
        Side side,
        uint256 price,
        uint256 orderId,
        uint256 amountBase,
        uint256 priceHint
    ) internal {
        Level storage level = side == Side.BUY ? book.bidLevels[price] : book.askLevels[price];
        if (!level.active) {
            _linkLevel(book, side, price, priceHint);
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

    function _linkLevel(Book storage book, Side side, uint256 price, uint256 priceHint) internal {
        mapping(uint256 => Level) storage levels = side == Side.BUY ? book.bidLevels : book.askLevels;
        uint256 best = side == Side.BUY ? book.bestBidPrice : book.bestAskPrice;
        Level storage level = levels[price];
        level.active = true;

        if (best == 0) {
            _setBest(book, side, price);
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
            _setBest(book, side, price);
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

    function _unlinkLevel(Book storage book, Side side, uint256 price) internal {
        mapping(uint256 => Level) storage levels = side == Side.BUY ? book.bidLevels : book.askLevels;
        Level storage level = levels[price];
        uint256 prev = level.prevPrice;
        uint256 next = level.nextPrice;
        if (prev != 0) levels[prev].nextPrice = next;
        if (next != 0) levels[next].prevPrice = prev;
        uint256 best = side == Side.BUY ? book.bestBidPrice : book.bestAskPrice;
        if (best == price) _setBest(book, side, next);
        delete levels[price];
    }

    function _setBest(Book storage book, Side side, uint256 price) internal {
        if (side == Side.BUY) book.bestBidPrice = price;
        else book.bestAskPrice = price;
    }
}
