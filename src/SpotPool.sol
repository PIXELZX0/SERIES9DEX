// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {FeeSplit} from "./libraries/FeeSplit.sol";
import {IOrderbook} from "./interfaces/IOrderbook.sol";

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
contract SpotPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant MAX_AUTO_FILLS = 5;

    address public immutable registry;
    address public immutable orderbook;
    address public immutable treasury;
    address public immutable token0;
    address public immutable token1;
    uint32 public immutable lpFeeRatePpm;
    bytes32 public immutable pairId;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint64 public blockTimestampLast;
    uint256 public protocolFees0;
    uint256 public protocolFees1;

    error InvalidToken();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientOutput();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidity();
    error InsufficientShares();
    error SlippageExceeded();
    error OnlyOrderbook();

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

    constructor(
        address registry_,
        address orderbook_,
        address treasury_,
        address token0_,
        address token1_,
        uint32 lpFeeRatePpm_,
        bytes32 pairId_
    ) {
        registry = registry_;
        orderbook = orderbook_;
        treasury = treasury_;
        token0 = token0_;
        token1 = token1_;
        lpFeeRatePpm = lpFeeRatePpm_;
        pairId = pairId_;
    }

    // ---------------------------------------------------------------- views

    function getReserves() external view returns (uint256, uint256, uint64) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function spotPriceX18() public view returns (uint256) {
        if (reserve0 == 0) revert InsufficientLiquidity();
        return reserve1 * 1e18 / reserve0;
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = _orientedReserves(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        (uint256 totalFee,,) = FeeSplit.split(amountIn, lpFeeRatePpm);
        uint256 effectiveIn = amountIn - totalFee;
        return reserveOut * effectiveIn / (reserveIn + effectiveIn);
    }

    // ------------------------------------------------------------ liquidity

    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 liquidity, uint256 used0, uint256 used1) {
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
        if (orderbook != address(0)) {
            // Post-swap auto-match (DEX.md §4.2). Runs after the reentrancy
            // lock is released so the orderbook may call swapFromOrderbook.
            // try/catch: a failing book must never revert the swap itself.
            try IOrderbook(orderbook).matchFromPool(pairId, MAX_AUTO_FILLS) {} catch {}
        }
    }

    function swapFromOrderbook(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != orderbook) revert OnlyOrderbook();
        // No auto-match hook here: prevents match recursion.
        amountOut = _swap(tokenIn, amountIn, minAmountOut, to);
    }

    function _swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        internal
        nonReentrant
        returns (uint256 amountOut)
    {
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

    /// @dev Accrue the TWAP accumulators against the *old* reserves, then
    /// store the new ones. Overflow wraps by design (UniV2 pattern);
    /// consumers subtract in unchecked blocks.
    function _update(uint256 newReserve0, uint256 newReserve1) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint256 timeElapsed = nowTs - blockTimestampLast;
        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            unchecked {
                price0CumulativeLast += (reserve1 * 1e18 / reserve0) * timeElapsed;
                price1CumulativeLast += (reserve0 * 1e18 / reserve1) * timeElapsed;
            }
        }
        reserve0 = newReserve0;
        reserve1 = newReserve1;
        blockTimestampLast = nowTs;
    }

    function _orientedReserves(address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == token0) return (reserve0, reserve1);
        if (tokenIn == token1) return (reserve1, reserve0);
        revert InvalidToken();
    }
}
