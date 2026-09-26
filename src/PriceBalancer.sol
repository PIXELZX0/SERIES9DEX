// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {IUniswapV2PairLike} from "./interfaces/external/IUniswapV2PairLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/external/IUniswapV3PoolLike.sol";

/// @notice Keeps one token pair priced the same across SERIES9 spot pools,
/// Uniswap and PancakeSwap (V2 and V3), by arbitraging them against each
/// other from an inventory this contract holds (docs/BALANCER.md).
///
/// A rebalance is a round trip through two venues in one transaction: sell
/// `tokenIn` where the other token is cheap, sell the other token back where
/// it is dear. At the profit-maximising size both pools end with the same
/// marginal price net of fees, which is as close as prices can be pulled
/// without paying for it. Pushing further would cost more in fees than the
/// spread returns, so the balancer never does.
///
/// Trust model:
///   - The owner (a Safe) decides which pools are venues and holds the
///     inventory. Only registered venues are ever called, so a keeper cannot
///     point a swap at a contract that just drains the allowance.
///   - Operators (hot keeper keys) can only trigger rebalances. Every
///     rebalance must end with more `tokenIn` than it started (by at least
///     `minProfit`) and no less of the other token, so a leaked operator key
///     can waste gas but cannot move value out.
///   - Holds no user funds and has no upgrade path.
contract PriceBalancer is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum VenueKind {
        None,
        /// SERIES9DEX `SpotPool`, must be registered in `DexRegistry`.
        Series9Spot,
        /// UniswapV2-style pair (Uniswap V2, PancakeSwap V2, forks).
        UniswapV2,
        /// UniswapV3-style pool (Uniswap V3, PancakeSwap V3).
        UniswapV3
    }

    struct Venue {
        VenueKind kind;
        /// Swap fee in ppm. Read from the pool where it reports one; set by
        /// the owner for V2 pairs, which do not.
        uint32 feePpm;
        address token0;
        address token1;
    }

    uint256 internal constant PPM = 1e6;
    uint256 internal constant Q96 = 1 << 96;
    // TickMath bounds, +1/-1 so an exact-in V3 swap never stops on a limit.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    int256 internal constant SIMULATION_FAILED = type(int256).min;

    uint256 public constant MAX_SEARCH_ITERATIONS = 64;

    address public immutable registry;

    mapping(address => Venue) internal _venues;
    mapping(address => bool) public isOperator;

    /// @dev The V3 pool whose swap callback is expected next. Only ever
    /// non-zero between `swap` and its callback, so a pool cannot be paid by
    /// calling back out of turn. Plain storage rather than transient so the
    /// contract does not depend on the chain supporting EIP-1153.
    address internal _pendingV3Pool;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidFee();
    error UnknownPool();
    error UnknownVenue();
    error SameVenue();
    error PairMismatch();
    error NotOperator();
    error NotConstantProduct();
    error InsufficientLiquidity();
    error InsufficientInventory();
    error InventoryLoss();
    error NotProfitable(uint256 profit, uint256 minProfit);
    error Expired();
    error TooManyIterations();
    error OnlySelf();
    error UnexpectedCallback();
    /// @dev Carries a simulated round trip's output out of a reverted call.
    error Simulated(uint256 amountOut);

    event VenueSet(address indexed pool, VenueKind kind, uint32 feePpm, address token0, address token1);
    event VenueRemoved(address indexed pool);
    event OperatorSet(address indexed operator, bool allowed);
    event Rebalanced(
        address indexed operator,
        address indexed firstVenue,
        address indexed secondVenue,
        address tokenIn,
        uint256 amountIn,
        uint256 profit
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address registry_, address owner_, address operator_) Ownable(owner_) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
        if (operator_ != address(0)) {
            isOperator[operator_] = true;
            emit OperatorSet(operator_, true);
        }
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    // ---------------------------------------------------------------- admin

    /// @notice Register, update or (with `VenueKind.None`) remove a venue.
    /// @param feePpm Only read for `UniswapV2`, whose pair does not report its
    /// fee: 3000 for Uniswap V2, 2500 for PancakeSwap V2. Setting it too low
    /// makes swaps revert on the pair's K check; too high only leaves dust in
    /// the pair. SERIES9 and V3 pools report their own fee.
    function setVenue(address pool, VenueKind kind, uint32 feePpm) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (kind == VenueKind.None) {
            delete _venues[pool];
            emit VenueRemoved(pool);
            return;
        }

        address token0;
        address token1;
        if (kind == VenueKind.Series9Spot) {
            if (!IDexRegistry(registry).isSpotPool(pool)) revert UnknownPool();
            feePpm = ISpotPool(pool).lpFeeRatePpm();
            (token0, token1) = (ISpotPool(pool).token0(), ISpotPool(pool).token1());
        } else if (kind == VenueKind.UniswapV2) {
            if (feePpm == 0 || feePpm >= PPM) revert InvalidFee();
            (token0, token1) = (IUniswapV2PairLike(pool).token0(), IUniswapV2PairLike(pool).token1());
        } else {
            feePpm = IUniswapV3PoolLike(pool).fee();
            (token0, token1) = (IUniswapV3PoolLike(pool).token0(), IUniswapV3PoolLike(pool).token1());
        }

        _venues[pool] = Venue(kind, feePpm, token0, token1);
        emit VenueSet(pool, kind, feePpm, token0, token1);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Take inventory (and accumulated profit) out.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    function venue(address pool) external view returns (Venue memory) {
        return _venues[pool];
    }

    /// @notice Spot price of `pool` as token1 per token0 in raw units, 1e18
    /// scaled — the same convention as `SpotPool.spotPriceX18`, so every
    /// venue of one pair is directly comparable.
    function priceX18(address pool) public view returns (uint256) {
        Venue memory v = _venue(pool);
        if (v.kind == VenueKind.UniswapV3) {
            uint256 sqrtPriceX96 = IUniswapV3PoolLike(pool).slot0();
            return Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), 1e18, Q96);
        }
        (uint256 reserve0, uint256 reserve1) = _reserves(pool, v);
        if (reserve0 == 0) revert InsufficientLiquidity();
        return Math.mulDiv(reserve1, 1e18, reserve0);
    }

    /// @notice Exact profit-maximising size for a round trip between two
    /// constant-product venues (SERIES9 spot and V2 pairs), in closed form.
    ///
    /// The two hops compose into one constant-product curve with virtual
    /// reserves `ra = a1*b2 / (b2 + g2*b1)` and `rb = g2*b1*a2 / (b2 + g2*b1)`
    /// behind the first hop's fee `g1`; profit `g1*x*rb/(ra + g1*x) - x` peaks
    /// at `x = (sqrt(g1*ra*rb) - ra) / g1`. Zero means no profitable size.
    function quoteOptimalAmountIn(address firstVenue, address secondVenue, address tokenIn)
        external
        view
        returns (uint256 amountIn, uint256 expectedProfit)
    {
        (Venue memory a, Venue memory b, address mid) = _route(firstVenue, secondVenue, tokenIn);
        if (a.kind == VenueKind.UniswapV3 || b.kind == VenueKind.UniswapV3) revert NotConstantProduct();

        (uint256 a1, uint256 b1) = _orientedReserves(firstVenue, a, tokenIn);
        (uint256 b2, uint256 a2) = _orientedReserves(secondVenue, b, mid);
        if (a1 == 0 || b1 == 0 || b2 == 0 || a2 == 0) revert InsufficientLiquidity();
        uint256 g1 = PPM - a.feePpm;
        uint256 g2 = PPM - b.feePpm;

        uint256 den = b2 * PPM + g2 * b1;
        uint256 ra = Math.mulDiv(a1, b2 * PPM, den);
        uint256 rb = Math.mulDiv(b1 * g2, a2, den);
        uint256 root = Math.sqrt(Math.mulDiv(ra, rb * g1, PPM));
        if (root <= ra) return (0, 0);

        amountIn = (root - ra) * PPM / g1;
        uint256 amountOut = Math.mulDiv(rb, amountIn * g1, ra * PPM + amountIn * g1);
        expectedProfit = amountOut > amountIn ? amountOut - amountIn : 0;
    }

    // ------------------------------------------------------------- search

    /// @notice Profit-maximising size for any two venues, V3 included, found
    /// by ternary search over real simulated round trips. Profit is concave
    /// in size for every supported curve, so the search converges.
    ///
    /// Not a view — each probe executes the swaps and reverts them — so call
    /// it with `eth_call`. Costs roughly two round trips per iteration.
    /// Searches up to `maxAmountIn`, capped at the inventory held; zero means
    /// the whole inventory.
    /// @return amountIn Zero when no size is profitable.
    /// @return profit Simulated profit at `amountIn`.
    function findOptimalAmountIn(
        address firstVenue,
        address secondVenue,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 iterations
    ) external nonReentrant returns (uint256 amountIn, uint256 profit) {
        if (iterations > MAX_SEARCH_ITERATIONS) revert TooManyIterations();
        _route(firstVenue, secondVenue, tokenIn);

        uint256 inventory = IERC20(tokenIn).balanceOf(address(this));
        if (maxAmountIn == 0 || maxAmountIn > inventory) maxAmountIn = inventory;

        uint256 lo = 0;
        uint256 hi = maxAmountIn;
        for (uint256 i = 0; i < iterations && hi - lo > 2; i++) {
            uint256 third = (hi - lo) / 3;
            uint256 m1 = lo + third;
            uint256 m2 = hi - third;
            if (
                _simulatedProfit(firstVenue, secondVenue, tokenIn, m1)
                    < _simulatedProfit(firstVenue, secondVenue, tokenIn, m2)
            ) {
                lo = m1;
            } else {
                hi = m2;
            }
        }

        amountIn = (lo + hi) / 2;
        int256 simulated = _simulatedProfit(firstVenue, secondVenue, tokenIn, amountIn);
        if (simulated <= 0) return (0, 0);
        profit = uint256(simulated);
    }

    /// @dev Entry point for the search's self-call. Always reverts: with
    /// `Simulated` on success, or with whatever the swap reverted with.
    function simulateRoundTrip(address firstVenue, address secondVenue, address tokenIn, uint256 amountIn) external {
        if (msg.sender != address(this)) revert OnlySelf();
        revert Simulated(_roundTrip(firstVenue, secondVenue, tokenIn, amountIn));
    }

    // ------------------------------------------------------------ rebalance

    /// @notice Swap `amountIn` of `tokenIn` for the other token at
    /// `firstVenue`, then all of that back at `secondVenue`.
    ///
    /// `firstVenue` is where the other token is cheapest in `tokenIn` terms
    /// (lowest `tokenIn` per other token), `secondVenue` where it is dearest.
    /// Reverts unless the contract ends with at least `minProfit` more
    /// `tokenIn` and no less of the other token.
    function rebalance(
        address firstVenue,
        address secondVenue,
        address tokenIn,
        uint256 amountIn,
        uint256 minProfit,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint256 profit) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        (,, address mid) = _route(firstVenue, secondVenue, tokenIn);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 midBefore = IERC20(mid).balanceOf(address(this));
        if (amountIn > inBefore) revert InsufficientInventory();

        _roundTrip(firstVenue, secondVenue, tokenIn, amountIn);

        if (IERC20(mid).balanceOf(address(this)) < midBefore) revert InventoryLoss();
        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        profit = inAfter > inBefore ? inAfter - inBefore : 0;
        if (inAfter < inBefore + minProfit) revert NotProfitable(profit, minProfit);

        emit Rebalanced(msg.sender, firstVenue, secondVenue, tokenIn, amountIn, profit);
    }

    // ----------------------------------------------------------- callbacks

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _payV3(amount0Delta, amount1Delta);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _payV3(amount0Delta, amount1Delta);
    }

    // ------------------------------------------------------------ internals

    function _payV3(int256 amount0Delta, int256 amount1Delta) internal {
        address pool = _pendingV3Pool;
        if (pool == address(0) || msg.sender != pool) revert UnexpectedCallback();
        _pendingV3Pool = address(0);
        Venue storage v = _venues[pool];
        if (amount0Delta > 0) IERC20(v.token0).safeTransfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(v.token1).safeTransfer(pool, uint256(amount1Delta));
    }

    /// @dev Signed profit of a simulated round trip; `SIMULATION_FAILED` if
    /// any swap reverted, so the search steers away from sizes that do.
    function _simulatedProfit(address firstVenue, address secondVenue, address tokenIn, uint256 amountIn)
        internal
        returns (int256)
    {
        if (amountIn == 0) return 0;
        try this.simulateRoundTrip(firstVenue, secondVenue, tokenIn, amountIn) {
            return SIMULATION_FAILED; // unreachable: it always reverts
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != Simulated.selector) return SIMULATION_FAILED;
            uint256 amountOut;
            assembly {
                amountOut := mload(add(reason, 36))
            }
            return SafeCast.toInt256(amountOut) - SafeCast.toInt256(amountIn);
        }
    }

    function _roundTrip(address firstVenue, address secondVenue, address tokenIn, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (Venue memory a, Venue memory b, address mid) = _route(firstVenue, secondVenue, tokenIn);

        // Balance deltas, not quoted amounts: the pools settle fee-on-transfer
        // tokens and SERIES9's post-swap order matching on their own terms.
        uint256 midBefore = IERC20(mid).balanceOf(address(this));
        _swap(firstVenue, a, tokenIn, amountIn);
        uint256 midReceived = IERC20(mid).balanceOf(address(this)) - midBefore;

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        _swap(secondVenue, b, mid, midReceived);
        amountOut = IERC20(tokenIn).balanceOf(address(this)) - inBefore;
    }

    function _swap(address pool, Venue memory v, address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == v.token0;
        if (v.kind == VenueKind.Series9Spot) {
            IERC20(tokenIn).forceApprove(pool, amountIn);
            ISpotPool(pool).swapExactIn(tokenIn, amountIn, 0, address(this));
        } else if (v.kind == VenueKind.UniswapV2) {
            IERC20(tokenIn).safeTransfer(pool, amountIn);
            (uint256 reserve0, uint256 reserve1,) = IUniswapV2PairLike(pool).getReserves();
            (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
            // What the pair actually received, as the pair itself will see it.
            uint256 inWithFee = (IERC20(tokenIn).balanceOf(pool) - reserveIn) * (PPM - v.feePpm);
            uint256 amountOut = inWithFee * reserveOut / (reserveIn * PPM + inWithFee);
            IUniswapV2PairLike(pool)
                .swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, address(this), new bytes(0));
        } else {
            _pendingV3Pool = pool;
            IUniswapV3PoolLike(pool)
                .swap(
                    address(this),
                    zeroForOne,
                    SafeCast.toInt256(amountIn),
                    zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
                    new bytes(0)
                );
            _pendingV3Pool = address(0);
        }
    }

    /// @dev Both venues must trade the same two tokens; returns the one that
    /// is not `tokenIn`.
    function _route(address firstVenue, address secondVenue, address tokenIn)
        internal
        view
        returns (Venue memory a, Venue memory b, address mid)
    {
        if (firstVenue == secondVenue) revert SameVenue();
        a = _venue(firstVenue);
        b = _venue(secondVenue);
        if (tokenIn == a.token0) mid = a.token1;
        else if (tokenIn == a.token1) mid = a.token0;
        else revert PairMismatch();
        bool samePair = (b.token0 == tokenIn && b.token1 == mid) || (b.token0 == mid && b.token1 == tokenIn);
        if (!samePair) revert PairMismatch();
    }

    function _venue(address pool) internal view returns (Venue memory v) {
        v = _venues[pool];
        if (v.kind == VenueKind.None) revert UnknownVenue();
    }

    function _reserves(address pool, Venue memory v) internal view returns (uint256 reserve0, uint256 reserve1) {
        if (v.kind == VenueKind.Series9Spot) {
            (reserve0, reserve1,) = ISpotPool(pool).getReserves();
        } else if (v.kind == VenueKind.UniswapV2) {
            (reserve0, reserve1,) = IUniswapV2PairLike(pool).getReserves();
        } else {
            revert NotConstantProduct();
        }
    }

    function _orientedReserves(address pool, Venue memory v, address tokenIn)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        (uint256 reserve0, uint256 reserve1) = _reserves(pool, v);
        return tokenIn == v.token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }
}
