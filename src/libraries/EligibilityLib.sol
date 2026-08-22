// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HomecomingTypes} from "./HomecomingTypes.sol";
import {ReferencePriceLib} from "./ReferencePriceLib.sol";

/// @notice Objective, deterministic routing-eligibility policy.
/// @dev Per MECHANISM.md §3/§20-21: this is a routing heuristic, not a claim about trader intent.
/// It never infers whether a trader is "benign" — it only decides whether a trade is small enough,
/// against enough liquidity, to be priced exactly by ReferencePriceLib.
library EligibilityLib {
    function evaluate(
        HomecomingTypes.Config memory config,
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickSpacing,
        uint128 poolLiquidity,
        uint24 lpFeePips,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (HomecomingTypes.Eligibility memory result) {
        result.sizeEligible = amountIn >= config.minAmountIn && poolLiquidity >= config.minLiquidity;

        if (!result.sizeEligible) {
            return result;
        }

        ReferencePriceLib.Quote memory quote = ReferencePriceLib.quoteExactInSingleRange(
            sqrtPriceX96, tick, tickSpacing, poolLiquidity, lpFeePips, amountIn, zeroForOne
        );

        result.withinCurrentRange = quote.withinCurrentRange;
        result.ammAmountOut = quote.amountOut;
    }

    function isEligible(HomecomingTypes.Eligibility memory result) internal pure returns (bool) {
        return result.sizeEligible && result.withinCurrentRange;
    }
}
