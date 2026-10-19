// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {FeeSplit} from "./libraries/FeeSplit.sol";
import {IPair} from "./interfaces/IPair.sol";
import {Pausing} from "./libraries/Pausing.sol";

/// @notice UniV2-style constant-product spot pool (DEX.md §5.1). Immutable:
/// fee rate is fixed at creation by the pool creator; the protocol cut (0.1%
/// of the lp fee) accrues separately and anyone may sweep it to the treasury.
/// Embeds a cumulative-price TWAP oracle consumed by perp pools, and triggers
/// bounded orderbook auto-matching after user swaps.
///
/// LP shares are a plain non-transferable ledger (`sharesOf`/`totalShares`) —
/// there is no fungible LP token. Transferable ownership of a position is the
/// ERC-721 minted by `DexPositionManager`, which custodies the shares. This
/// mirrors Uniswap V3, where the core pool tracks positions and only the
/// periphery tokenizes them.
///
/// Prices are raw token1 units per raw token0 unit, scaled by 1e36. At 1e18
/// a pair whose raw price is tiny — an 18-decimal base against a 6-decimal
/// quote at $0.00001 is 1e-17 — kept one significant digit, and anything
/// below 1e-18 read as zero. 1e36 keeps six digits down to a raw price of
/// 1e-30, and reserves are capped at uint112 so `reserve * 1e36` cannot
/// overflow.
contract SpotPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev State of the pool just before the first update of an oracle
    /// epoch: the accumulators and reserves as of the update before it, and
    /// that update's timestamp. Nothing changed in between, so the pool's
    /// price and depth at any instant in [timestamp, this epoch's first
    /// update] follow from this record alone.
    struct Observation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint256 inverseLiquidityCumulative;
        uint112 reserve0;
        uint112 reserve1;
        uint32 timestamp;
    }

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant MAX_AUTO_FILLS = 5;
    /// @notice Perp marks are read at multiples of this many seconds.
    uint256 public constant ORACLE_EPOCH = 60;
    /// @notice Empty epochs `observe` walks over before it asks for a hint:
    /// an hour of idleness, a few cold reads each, so only a request
    /// executed long after an idle stretch needs one.
    uint256 public constant MAX_OBSERVATION_PROBES = 64;
    uint256 internal constant PPM = 1e6;
    uint256 internal constant PRICE_SCALE = 1e36;

    address public immutable registry;
    address public immutable pair;
    address public immutable treasury;
    address public immutable token0;
    address public immutable token1;
    uint32 public immutable lpFeeRatePpm;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public price0CumulativeLast; // X36, wraps by design
    uint256 public price1CumulativeLast; // X36, wraps by design
    /// @notice Running sum of 1e36 / sqrt(reserve0 * reserve1) per second.
    /// Perps size open interest against this pool's depth by the harmonic
    /// mean it gives: a stretch of thin pool dominates it however short
    /// the deep stretches around it, where an arithmetic mean of the depth
    /// could be held up by a moment of borrowed liquidity. Wraps by design.
    uint256 public inverseLiquidityCumulativeLast;
    uint64 public blockTimestampLast;
    uint256 public protocolFees0;
    uint256 public protocolFees1;

    /// @notice Set by the pair once a perp market prices off this pool.
    /// Recording observations costs a few storage writes per epoch, which a
    /// pool nothing reads from has no reason to pay.
    bool public oracleEnabled;
    mapping(uint256 => Observation) internal _observations; // epoch index => observation

    error InvalidToken();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientOutput();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidity();
    error InsufficientShares();
    error SlippageExceeded();
    error OnlyPair();
    error ReserveOverflow();
    error ObservationUnavailable();
    error ObservationHintRequired();
    error InvalidObservationHint();

    event LiquidityAdded(
        address indexed provider, address indexed to, uint256 amount0, uint256 amount1, uint256 liquidity
    );
    event LiquidityRemoved(
        address indexed provider, address indexed to, uint256 amount0, uint256 amount1, uint256 liquidity
    );
    event Swapped(
        address indexed sender, address indexed to, address indexed tokenIn, uint256 amountIn, uint256 amountOut
    );
    event ProtocolFeesCollected(uint256 amount0, uint256 amount1);
    event Skimmed(address indexed to, uint256 amount0, uint256 amount1);
    event OracleEnabled();

    constructor(
        address registry_,
        address pair_,
        address treasury_,
        address token0_,
        address token1_,
        uint32 lpFeeRatePpm_
    ) {
        registry = registry_;
        pair = pair_;
        treasury = treasury_;
        token0 = token0_;
        token1 = token1_;
        lpFeeRatePpm = lpFeeRatePpm_;
    }

    // ---------------------------------------------------------------- views

    function getReserves() external view returns (uint256, uint256, uint64) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function spotPriceX36() public view returns (uint256) {
        if (reserve0 == 0) revert InsufficientLiquidity();
        return reserve1 * PRICE_SCALE / reserve0;
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = _orientedReserves(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        (uint256 totalFee,,) = FeeSplit.split(amountIn, lpFeeRatePpm);
        uint256 effectiveIn = amountIn - totalFee;
        return Math.mulDiv(reserveOut, effectiveIn, reserveIn + effectiveIn);
    }

    /// @notice Input required to get at least `amountOut` out, fee included.
    /// The fee rounds up, so `amountIn - fee(amountIn)` is
    /// `floor(amountIn * (1e6 - fee) / 1e6)` and the smallest input clearing
    /// `effectiveIn` is exactly the ceiling below: quoting then swapping this
    /// amount never falls a wei short of the target, and never overpays.
    function getAmountIn(address tokenIn, uint256 amountOut) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = _orientedReserves(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        uint256 effectiveIn = Math.mulDiv(reserveIn, amountOut, reserveOut - amountOut, Math.Rounding.Ceil);
        return Math.mulDiv(effectiveIn, PPM, PPM - lpFeeRatePpm, Math.Rounding.Ceil);
    }

    /// @notice The accumulators as of the epoch boundary `epoch * ORACLE_EPOCH`.
    ///
    /// The first update at or after a boundary always starts a new epoch, so
    /// it is the one that wrote the observation covering that boundary. For
    /// an active pool that record sits at the boundary's own index; after an
    /// idle stretch it sits further on, and `hint` names its index. With no
    /// hint the walk covers `MAX_OBSERVATION_PROBES` empty epochs, which is
    /// always enough for a boundary within that many epochs of the last
    /// update.
    ///
    /// Also returns the reserves in effect at the boundary.
    ///
    /// Reverts `ObservationUnavailable` when the boundary predates the pool's
    /// liquidity or its oracle being enabled — a fact about history, so it
    /// never turns into a value later.
    function observe(uint256 epoch, uint256 hint)
        external
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint256 inverseLiquidityCumulative,
            uint256 reserve0At,
            uint256 reserve1At
        )
    {
        uint256 target = epoch * ORACLE_EPOCH;
        if (target > block.timestamp) revert ObservationUnavailable();
        uint256 last = blockTimestampLast;

        Observation memory o;
        if (target > last) {
            // Nothing has happened since the boundary: the live state covers it.
            // An update in the boundary's own second goes to the record below
            // instead, so the reserves reported for a boundary are those in
            // effect up to it — the same answer before and after later trades.
            o = Observation(
                price0CumulativeLast,
                price1CumulativeLast,
                inverseLiquidityCumulativeLast,
                uint112(reserve0),
                uint112(reserve1),
                uint32(last)
            );
        } else if (hint != 0) {
            o = _observations[hint];
            if (o.reserve0 == 0 || hint < epoch || o.timestamp >= target) revert InvalidObservationHint();
        } else {
            uint256 lastEpoch = last / ORACLE_EPOCH;
            uint256 i = epoch;
            o = _observations[i];
            while (o.reserve0 == 0) {
                // The covering update is never later than the last one; if no
                // record turns up by then, it was made before recording began.
                if (i >= lastEpoch) revert ObservationUnavailable();
                if (i - epoch >= MAX_OBSERVATION_PROBES) revert ObservationHintRequired();
                o = _observations[++i];
            }
            if (o.timestamp >= target) revert ObservationUnavailable();
        }
        if (o.reserve0 == 0 || o.reserve1 == 0) revert ObservationUnavailable();

        uint256 dt = target - o.timestamp;
        unchecked {
            price0Cumulative = o.price0Cumulative + (uint256(o.reserve1) * PRICE_SCALE / o.reserve0) * dt;
            price1Cumulative = o.price1Cumulative + (uint256(o.reserve0) * PRICE_SCALE / o.reserve1) * dt;
            inverseLiquidityCumulative =
                o.inverseLiquidityCumulative + dt * PRICE_SCALE / Math.sqrt(uint256(o.reserve0) * o.reserve1);
        }
        (reserve0At, reserve1At) = (o.reserve0, o.reserve1);
    }

    // ------------------------------------------------------------- oracle

    function enableOracle() external {
        if (msg.sender != pair) revert OnlyPair();
        if (oracleEnabled) return;
        oracleEnabled = true;
        emit OracleEnabled();
    }

    // ------------------------------------------------------------ liquidity

    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 liquidity, uint256 used0, uint256 used1) {
        Pausing.requireNotPaused(registry);
        if (to == address(0)) revert ZeroAddress();
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        uint256 want0;
        uint256 want1;
        if (_reserve0 == 0 && _reserve1 == 0) {
            (want0, want1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = amount0Desired * _reserve1 / _reserve0;
            if (amount1Optimal <= amount1Desired) {
                (want0, want1) = (amount0Desired, amount1Optimal);
            } else {
                (want0, want1) = (amount1Desired * _reserve0 / _reserve1, amount1Desired);
            }
        }
        if (want0 == 0 || want1 == 0) revert ZeroAmount();

        used0 = _pull(token0, want0);
        used1 = _pull(token1, want1);
        if (used0 < amount0Min || used1 < amount1Min) revert SlippageExceeded();

        uint256 supply = totalShares;
        if (supply == 0) {
            liquidity = Math.sqrt(used0 * used1) - MINIMUM_LIQUIDITY;
            _mintShares(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(used0 * supply / _reserve0, used1 * supply / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mintShares(to, liquidity);

        _update(_reserve0 + used0, _reserve1 + used1);
        emit LiquidityAdded(msg.sender, to, used0, used1, liquidity);
    }

    function removeLiquidity(uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (to == address(0)) revert ZeroAddress();
        // Checked first so a caller without the shares gets a clear error
        // instead of a divide-by-zero panic on an empty pool.
        if (liquidity > sharesOf[msg.sender]) revert InsufficientShares();
        uint256 supply = totalShares;
        amount0 = liquidity * reserve0 / supply;
        amount1 = liquidity * reserve1 / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        _burnShares(msg.sender, liquidity);
        _update(reserve0 - amount0, reserve1 - amount1);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);
        emit LiquidityRemoved(msg.sender, to, amount0, amount1, liquidity);
    }

    // ----------------------------------------------------------------- swap

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        amountOut = _swap(tokenIn, amountIn, minAmountOut, to);
        if (pair != address(0)) {
            // Post-swap auto-match (DEX.md §4.2). Runs after the reentrancy
            // lock is released so the pair may call swapFromPair.
            // try/catch: a failing book must never revert the swap itself.
            try IPair(pair).matchFromPool(MAX_AUTO_FILLS) {} catch {}
        }
    }

    function swapFromPair(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != pair) revert OnlyPair();
        // No auto-match hook here: prevents match recursion.
        amountOut = _swap(tokenIn, amountIn, minAmountOut, to);
    }

    function _swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        internal
        nonReentrant
        returns (uint256 amountOut)
    {
        Pausing.requireNotPaused(registry);
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        (uint256 reserveIn, uint256 reserveOut) = _orientedReserves(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 received = _pull(tokenIn, amountIn);
        (, uint256 protocolFee,) = FeeSplit.split(received, lpFeeRatePpm);
        amountOut = getAmountOut(tokenIn, received);
        if (amountOut < minAmountOut) revert InsufficientOutput();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        address tokenOut;
        if (tokenIn == token0) {
            protocolFees0 += protocolFee;
            tokenOut = token1;
            _update(reserve0 + received - protocolFee, reserve1 - amountOut);
        } else {
            protocolFees1 += protocolFee;
            tokenOut = token0;
            _update(reserve0 - amountOut, reserve1 + received - protocolFee);
        }
        IERC20(tokenOut).safeTransfer(to, amountOut);
        emit Swapped(msg.sender, to, tokenIn, received, amountOut);
    }

    // ------------------------------------------------------------------ fees

    /// @notice Send any balance the pool is not accounting for to `to`.
    /// Reserves only move through this contract's own bookkeeping, so a
    /// surplus is a direct transfer someone made to the pool — without this it
    /// sits here forever, owned by nobody.
    ///
    /// Subtracts the accrued protocol fees as well as the reserves: those are
    /// held in the pool's balance but are not part of it, and skimming them
    /// would be stealing from the treasury.
    ///
    /// Permissionless and unrestricted in `to`, as in UniswapV2 — a donation
    /// to a pool is finders-keepers, not a claim.
    function skim(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 surplus0 = IERC20(token0).balanceOf(address(this)) - reserve0 - protocolFees0;
        uint256 surplus1 = IERC20(token1).balanceOf(address(this)) - reserve1 - protocolFees1;
        if (surplus0 > 0) IERC20(token0).safeTransfer(to, surplus0);
        if (surplus1 > 0) IERC20(token1).safeTransfer(to, surplus1);
        emit Skimmed(to, surplus0, surplus1);
    }

    function collectProtocolFees() external nonReentrant {
        uint256 fee0 = protocolFees0;
        uint256 fee1 = protocolFees1;
        protocolFees0 = 0;
        protocolFees1 = 0;
        if (fee0 > 0) IERC20(token0).safeTransfer(treasury, fee0);
        if (fee1 > 0) IERC20(token1).safeTransfer(treasury, fee1);
        emit ProtocolFeesCollected(fee0, fee1);
    }

    // ------------------------------------------------------------- internals

    function _mintShares(address to, uint256 amount) internal {
        totalShares += amount;
        sharesOf[to] += amount;
    }

    function _burnShares(address from, uint256 amount) internal {
        uint256 balance = sharesOf[from];
        if (amount > balance) revert InsufficientShares();
        sharesOf[from] = balance - amount;
        totalShares -= amount;
    }

    /// @dev Pull tokens and credit by balance delta (fee-on-transfer support).
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();
    }

    /// @dev Accrue the accumulators against the *old* reserves, then store the
    /// new ones. Overflow wraps by design (UniV2 pattern); consumers subtract
    /// in unchecked blocks. The first update of an oracle epoch first records
    /// the state it is about to overwrite, which is what `observe` reads.
    function _update(uint256 newReserve0, uint256 newReserve1) internal {
        if (newReserve0 > type(uint112).max || newReserve1 > type(uint112).max) revert ReserveOverflow();
        uint256 last = blockTimestampLast;
        uint256 timeElapsed = block.timestamp - last;
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        if (timeElapsed > 0 && r0 > 0 && r1 > 0) {
            if (oracleEnabled && block.timestamp / ORACLE_EPOCH > last / ORACLE_EPOCH) {
                _observations[block.timestamp / ORACLE_EPOCH] = Observation(
                    price0CumulativeLast,
                    price1CumulativeLast,
                    inverseLiquidityCumulativeLast,
                    uint112(r0),
                    uint112(r1),
                    uint32(last)
                );
            }
            unchecked {
                price0CumulativeLast += (r1 * PRICE_SCALE / r0) * timeElapsed;
                price1CumulativeLast += (r0 * PRICE_SCALE / r1) * timeElapsed;
                inverseLiquidityCumulativeLast += timeElapsed * PRICE_SCALE / Math.sqrt(r0 * r1);
            }
        }
        reserve0 = newReserve0;
        reserve1 = newReserve1;
        blockTimestampLast = uint64(block.timestamp);
    }

    function _orientedReserves(address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == token0) return (reserve0, reserve1);
        if (tokenIn == token1) return (reserve1, reserve0);
        revert InvalidToken();
    }
}
