// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";

/// @notice Stateless multi-hop swap periphery, plus the deadline the pools
/// deliberately do not carry.
///
/// The path is an explicit list of spot pools, as in Uniswap V3: which fee
/// tier each hop uses is the caller's decision, made off-chain against
/// `Pair.spotPools`, not something the router rediscovers on-chain. Doing it
/// any other way would put a pool-scanning loop in the hot path of every
/// swap, which is exactly the cost the pair's own matching loop already pays.
///
/// Every pool is checked against the registry before the router approves it,
/// so a caller cannot point a hop at a contract that merely looks like a pool
/// and drain the allowance the caller just granted.
///
/// The router holds no balance between calls and has no owner, no upgrade
/// path and no privileged entry point. Each hop lands in the router and is
/// credited by balance delta, so fee-on-transfer tokens work; the final
/// amount is forwarded to `to` in one transfer.
contract DexRouter {
    using SafeERC20 for IERC20;

    address public immutable registry;

    error ZeroAddress();
    error Expired();
    error EmptyPath();
    error UnknownPool();
    error InsufficientOutput();

    event Swapped(address indexed sender, address indexed to, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ----------------------------------------------------------------- swap

    /// @param pools One spot pool per hop, in order. `tokenIn` must be one of
    /// the first pool's two tokens; each later hop takes the previous hop's
    /// output token.
    function swapExactTokensForTokens(
        address[] calldata pools,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountOut) {
        if (pools.length == 0) revert EmptyPath();
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert InsufficientOutput();

        address token = tokenIn;
        uint256 amount = _pull(tokenIn, amountIn);

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            if (!IDexRegistry(registry).isSpotPool(pool)) revert UnknownPool();
            address tokenOut = _otherToken(pool, token);
            uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
            IERC20(token).forceApprove(pool, amount);
            // Per-hop bound is left to the final check: an intermediate
            // minimum would only be a second, weaker way to say the same
            // thing, and the pool reverts on its own if it cannot fill.
            ISpotPool(pool).swapExactIn(token, amount, 0, address(this));
            amount = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
            token = tokenOut;
        }

        amountOut = amount;
        if (amountOut < minAmountOut) revert InsufficientOutput();
        IERC20(token).safeTransfer(to, amountOut);
        emit Swapped(msg.sender, to, tokenIn, amountIn, amountOut);
    }

    // --------------------------------------------------------------- quotes

    /// @notice Output for `amountIn` along `pools`, at current reserves.
    /// Ignores fee-on-transfer tokens, which no on-chain quote can see.
    function quoteExactInput(address[] calldata pools, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (pools.length == 0) revert EmptyPath();
        address token = tokenIn;
        amountOut = amountIn;
        for (uint256 i = 0; i < pools.length; i++) {
            amountOut = ISpotPool(pools[i]).getAmountOut(token, amountOut);
            token = _otherToken(pools[i], token);
        }
    }

    /// @notice Input needed for `amountOut` along `pools`. Walks the path
    /// forward once to learn each hop's input token, then prices backwards.
    function quoteExactOutput(address[] calldata pools, address tokenIn, uint256 amountOut)
        external
        view
        returns (uint256 amountIn)
    {
        if (pools.length == 0) revert EmptyPath();
        address[] memory hopTokens = new address[](pools.length);
        address token = tokenIn;
        for (uint256 i = 0; i < pools.length; i++) {
            hopTokens[i] = token;
            token = _otherToken(pools[i], token);
        }
        amountIn = amountOut;
        for (uint256 i = pools.length; i > 0; i--) {
            amountIn = ISpotPool(pools[i - 1]).getAmountIn(hopTokens[i - 1], amountIn);
        }
    }

    // ------------------------------------------------------------ internals

    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InsufficientOutput();
    }

    /// @dev The other side of `pool`. A `tokenIn` belonging to neither side
    /// falls through to token0 and the pool itself reverts `InvalidToken`, so
    /// there is nothing to re-check here.
    function _otherToken(address pool, address tokenIn) internal view returns (address) {
        address token0 = ISpotPool(pool).token0();
        return tokenIn == token0 ? ISpotPool(pool).token1() : token0;
    }
}
