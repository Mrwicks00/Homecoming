// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReferencePriceLib} from "../../src/libraries/ReferencePriceLib.sol";

/// @notice Thin external surface over ReferencePriceLib so its `internal` helpers can be unit
/// tested directly (notably the negative-tick floor path in `_compressToTickLower`, which plain
/// integer division gets wrong).
contract ReferencePriceLibHarness {
    function quote(
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickSpacing,
        uint128 liquidity,
        uint24 lpFeePips,
        uint256 amountIn,
        bool zeroForOne
    ) external pure returns (bool withinCurrentRange, uint256 amountOut) {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            sqrtPriceX96, tick, tickSpacing, liquidity, lpFeePips, amountIn, zeroForOne
        );
        return (q.withinCurrentRange, q.amountOut);
    }

    function compressToTickLower(int24 tick, int24 tickSpacing) external pure returns (int24) {
        return ReferencePriceLib._compressToTickLower(tick, tickSpacing);
    }
}
