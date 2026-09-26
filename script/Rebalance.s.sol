// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PriceBalancer} from "../src/PriceBalancer.sol";

/// @notice One keeper tick: read every venue's price, and if the widest
/// spread is worth closing, size the trade and send one `rebalance`.
///
/// Sizing runs locally against the fork before anything is broadcast, so the
/// search's many simulated swaps cost nothing on-chain. Run it on a timer
/// (script/keeper.sh) — each tick closes the widest gap, and repeated ticks
/// pull every venue into one fee band of each other.
///
/// Env:
///   BALANCER              PriceBalancer address
///   VENUES                comma-separated registered venues of one pair
///   TOKEN_IN              inventory token the round trip starts and ends in
///   OPERATOR_PRIVATE_KEY  keeper key
///   MIN_PROFIT            absolute floor in TOKEN_IN units (default 1)
///   MIN_SPREAD_BPS        skip below this spread (default 0)
///   PROFIT_SLIPPAGE_BPS   accept down to expected profit minus this (default 1000)
///   MAX_AMOUNT_IN         cap per trade, 0 = whole inventory (default 0)
///   SEARCH_ITERATIONS     ternary search steps when a V3 venue is involved (default 30)
contract Rebalance is Script {
    function run() external {
        PriceBalancer balancer = PriceBalancer(vm.envAddress("BALANCER"));
        address[] memory venues = vm.envAddress("VENUES", ",");
        address tokenIn = vm.envAddress("TOKEN_IN");
        uint256 minSpreadBps = vm.envOr("MIN_SPREAD_BPS", uint256(0));
        require(venues.length >= 2, "VENUES needs at least two pools");

        // Price of the other token, in TOKEN_IN, at each venue. The first leg
        // buys where it is cheapest; the second sells where it is dearest.
        (address first, address second) = (address(0), address(0));
        (uint256 lowest, uint256 highest) = (type(uint256).max, 0);
        for (uint256 i = 0; i < venues.length; i++) {
            uint256 price = _priceInTokenIn(balancer, venues[i], tokenIn);
            console.log("venue", venues[i], "price x1e18", price);
            if (price < lowest) (lowest, first) = (price, venues[i]);
            if (price > highest) (highest, second) = (price, venues[i]);
        }

        uint256 spreadBps = (highest - lowest) * 10_000 / lowest;
        console.log("spread bps", spreadBps);
        if (first == second || spreadBps < minSpreadBps) {
            console.log("spread below threshold, nothing to do");
            return;
        }

        (uint256 amountIn, uint256 expected) = _size(balancer, first, second, tokenIn);
        uint256 minProfit = expected * (10_000 - vm.envOr("PROFIT_SLIPPAGE_BPS", uint256(1_000))) / 10_000;
        uint256 floor = vm.envOr("MIN_PROFIT", uint256(1));
        if (minProfit < floor) minProfit = floor;
        console.log("amountIn", amountIn);
        console.log("expected profit", expected);
        if (amountIn == 0 || expected < minProfit) {
            console.log("not profitable after fees, nothing to do");
            return;
        }

        vm.startBroadcast(vm.envUint("OPERATOR_PRIVATE_KEY"));
        uint256 profit = balancer.rebalance(first, second, tokenIn, amountIn, minProfit, block.timestamp + 120);
        vm.stopBroadcast();
        console.log("profit", profit);
    }

    function _size(PriceBalancer balancer, address first, address second, address tokenIn)
        internal
        returns (uint256 amountIn, uint256 expected)
    {
        uint256 maxAmountIn = vm.envOr("MAX_AMOUNT_IN", uint256(0));
        bool anyV3 = balancer.venue(first).kind == PriceBalancer.VenueKind.UniswapV3
            || balancer.venue(second).kind == PriceBalancer.VenueKind.UniswapV3;
        if (!anyV3) {
            (amountIn, expected) = balancer.quoteOptimalAmountIn(first, second, tokenIn);
            // Capped below the optimum: profit is concave, so a smaller trade
            // is still profitable, just less so. Re-simulate for the real figure.
            if (maxAmountIn == 0 || amountIn <= maxAmountIn) return (amountIn, expected);
        }
        uint256 iterations = vm.envOr("SEARCH_ITERATIONS", uint256(30));
        return balancer.findOptimalAmountIn(first, second, tokenIn, maxAmountIn, iterations);
    }

    function _priceInTokenIn(PriceBalancer balancer, address pool, address tokenIn) internal view returns (uint256) {
        PriceBalancer.Venue memory v = balancer.venue(pool);
        require(tokenIn == v.token0 || tokenIn == v.token1, "TOKEN_IN not in venue");
        uint256 price = balancer.priceX18(pool); // token1 per token0
        return tokenIn == v.token1 ? price : 1e36 / price;
    }
}
