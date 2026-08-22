// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ReferencePriceLib} from "../../src/libraries/ReferencePriceLib.sol";

contract ReferencePriceLibTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_3000 = 3000;
    uint128 constant DEEP_LIQUIDITY = 1e24;

    /// @dev Regression test for the exact bug caught by the integration test suite: when the
    /// current price sits EXACTLY on a tick-spacing boundary (tick=0 is a multiple of 60) and the
    /// swap direction is zeroForOne (price decreasing), a naive "current cell" computation picks a
    /// target equal to the current price itself — zero room to move — and would incorrectly mark
    /// every such trade as crossing the cell. See ARCHITECTURE_VALIDATION.md §5 / ReferencePriceLib
    /// NatSpec for the fix (mirrors the boundary subtlety documented on IPoolManager.donate()).
    function test_regression_exactBoundaryTick_zeroForOne_staysWithinRange() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true
        );
        assertTrue(q.withinCurrentRange, "a small trade from an exact tick-spacing boundary must be priceable");
        assertGt(q.amountOut, 0);
    }

    function test_regression_exactBoundaryTick_oneForZero_staysWithinRange() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, false
        );
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    function test_smallTrade_deepLiquidity_producesFeeInclusiveOutput() public pure {
        uint256 amountIn = 1e18;
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, true);

        assertTrue(q.withinCurrentRange);
        // Near price 1:1 with deep liquidity, output should be close to but strictly less than
        // amountIn (0.3% pool fee, plus a tiny amount of price impact).
        assertLt(q.amountOut, amountIn, "output must reflect the pool fee");
        assertGt(q.amountOut, amountIn * 99 / 100, "output should be close to amountIn given deep liquidity");
    }

    function test_hugeTrade_thinLiquidity_correctlyRefusesToPrice() public pure {
        // A trade that would consume far more than the current cell can support at shallow
        // liquidity must be reported as NOT priceable, not approximated.
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, 1e12, FEE_3000, 1e18, true
        );
        assertFalse(q.withinCurrentRange, "an oversized trade against thin liquidity must not be priced");
    }

    function testFuzz_neverPricesBeyondTheCurrentCell(uint256 amountIn, bool zeroForOne) public pure {
        amountIn = bound(amountIn, 1, 1e30);
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, zeroForOne
        );
        // Whatever the outcome, amountOut is only ever populated when a valid, boundary-respecting
        // quote was found — never a nonzero-but-wrong value on the "not priceable" path.
        if (!q.withinCurrentRange) {
            assertEq(q.amountOut, 0);
        }
    }
}
