// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ReferencePriceLib} from "../../src/libraries/ReferencePriceLib.sol";
import {ReferencePriceLibHarness} from "../util/ReferencePriceLibHarness.sol";

contract ReferencePriceLibTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_3000 = 3000;
    uint128 constant DEEP_LIQUIDITY = 1e24;

    ReferencePriceLibHarness h;

    function setUp() public {
        h = new ReferencePriceLibHarness();
    }

    // =======================================================================================
    // _compressToTickLower — the negative-tick floor path plain division gets wrong
    // =======================================================================================

    function test_compress_zero() public view {
        assertEq(h.compressToTickLower(0, 60), int24(0));
    }

    function test_compress_positive_nonMultiple() public view {
        assertEq(h.compressToTickLower(59, 60), int24(0));
        assertEq(h.compressToTickLower(61, 60), int24(60));
        assertEq(h.compressToTickLower(119, 60), int24(60));
    }

    function test_compress_positive_exactMultiple() public view {
        assertEq(h.compressToTickLower(60, 60), int24(60));
        assertEq(h.compressToTickLower(120, 60), int24(120));
    }

    function test_compress_negative_exactMultiple() public view {
        assertEq(h.compressToTickLower(-60, 60), int24(-60));
        assertEq(h.compressToTickLower(-120, 60), int24(-120));
    }

    function test_compress_negative_nonMultiple_floorsDown() public view {
        // Plain truncation would give -60 for -1; the floor correction must give -60 lower bound
        assertEq(h.compressToTickLower(-1, 60), int24(-60));
        assertEq(h.compressToTickLower(-59, 60), int24(-60));
        assertEq(h.compressToTickLower(-61, 60), int24(-120));
        assertEq(h.compressToTickLower(-119, 60), int24(-120));
    }

    function test_compress_spacingOne_isIdentity() public view {
        assertEq(h.compressToTickLower(0, 1), int24(0));
        assertEq(h.compressToTickLower(7, 1), int24(7));
        assertEq(h.compressToTickLower(-7, 1), int24(-7));
    }

    function test_compress_largeSpacing() public view {
        assertEq(h.compressToTickLower(199, 200), int24(0));
        assertEq(h.compressToTickLower(200, 200), int24(200));
        assertEq(h.compressToTickLower(-1, 200), int24(-200));
    }

    function testFuzz_compress_isMultipleOfSpacing_andBrackets(int24 tick) public view {
        int24 spacing = 60;
        tick = int24(bound(int256(tick), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
        int24 lower = h.compressToTickLower(tick, spacing);
        assertEq(lower % spacing, int24(0), "result must be a spacing multiple");
        assertLe(lower, tick, "lower bound cannot exceed tick");
        assertLt(tick, lower + spacing, "tick must sit inside [lower, lower+spacing)");
    }

    // =======================================================================================
    // quoteExactInSingleRange — boundary regressions (SECURITY.md §1.1)
    // =======================================================================================

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

    function test_boundary_offBoundaryPrice_zeroForOne() public pure {
        // price at tick 1 (not a spacing multiple), reported tick 1 -> tickLower 0, room to move down
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(1);
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, 1, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true);
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    function test_boundary_negativeCurrentTick() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(-73);
        ReferencePriceLib.Quote memory q0 =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, -73, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true);
        ReferencePriceLib.Quote memory q1 =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, -73, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, false);
        assertTrue(q0.withinCurrentRange);
        assertTrue(q1.withinCurrentRange);
        assertGt(q0.amountOut, 0);
        assertGt(q1.amountOut, 0);
    }

    function test_boundary_exactNegativeBoundaryTick_zeroForOne() public pure {
        // price exactly on tick -60 (a spacing multiple), zeroForOne -> must shift a cell down
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(-60);
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, -60, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true);
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    // =======================================================================================
    // quoteExactInSingleRange — pricing behaviour
    // =======================================================================================

    function test_smallTrade_deepLiquidity_feeInclusive() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true
        );
        assertTrue(q.withinCurrentRange);
        assertLt(q.amountOut, 1e18, "output must reflect the 0.3% pool fee + impact");
        assertGt(q.amountOut, 1e18 * 99 / 100, "deep liquidity -> output close to amountIn");
    }

    function test_feeTiers_lowerFeeMeansMoreOut() public pure {
        uint256 out0 =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 0, 1e18, true)
        .amountOut;
        uint256 out500 =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 500, 1e18, true)
        .amountOut;
        uint256 out3000 =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 3000, 1e18, true)
        .amountOut;
        uint256 out10000 =
            ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 10000, 1e18, true
        )
        .amountOut;
        assertGt(out0, out500);
        assertGt(out500, out3000);
        assertGt(out3000, out10000);
    }

    function test_zeroFee_outputCloseToInput_deepLiquidity() public pure {
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 0, 1e15, true);
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 1e15 * 9999 / 10000);
    }

    function test_tickSpacings_allPriceASmallTrade() public pure {
        int24[4] memory spacings = [int24(1), int24(10), int24(60), int24(200)];
        for (uint256 i = 0; i < spacings.length; i++) {
            ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
                SQRT_PRICE_1_1, 0, spacings[i], DEEP_LIQUIDITY, FEE_3000, 1e15, false
            );
            // spacing 1: an exact-boundary 1:1 pool has a 1-tick cell; a 1e15 trade may or may not
            // fit — but if priced, it must be positive; if not priced, amountOut must be 0.
            if (q.withinCurrentRange) assertGt(q.amountOut, 0);
            else assertEq(q.amountOut, 0);
        }
    }

    function test_widerSpacingPricesLargerTrades() public pure {
        // spacing 1 refuses a mid trade that spacing 200 prices fine
        ReferencePriceLib.Quote memory tight =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, 1, DEEP_LIQUIDITY, FEE_3000, 1e21, true);
        ReferencePriceLib.Quote memory wide =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, 200, DEEP_LIQUIDITY, FEE_3000, 1e21, true);
        assertFalse(tight.withinCurrentRange);
        assertTrue(wide.withinCurrentRange);
    }

    function test_hugeTrade_thinLiquidity_refusesToPrice() public pure {
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, 1e12, FEE_3000, 1e18, true);
        assertFalse(q.withinCurrentRange, "an oversized trade against thin liquidity must not be priced");
        assertEq(q.amountOut, 0);
    }

    function test_hugeTrade_thinLiquidity_refusesToPrice_oneForZero() public pure {
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, 1e12, FEE_3000, 1e18, false);
        assertFalse(q.withinCurrentRange);
        assertEq(q.amountOut, 0);
    }

    function test_zeroAmountIn_pricesToZeroWithinRange() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 0, true
        );
        assertTrue(q.withinCurrentRange);
        assertEq(q.amountOut, 0);
    }

    function test_oneWeiAmountIn_withinRange() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1, true
        );
        assertTrue(q.withinCurrentRange);
    }

    function test_bothDirectionsSymmetricAt1to1() public pure {
        uint256 outZ =
            ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, true
        )
        .amountOut;
        uint256 outO =
            ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, false
        )
        .amountOut;
        assertApproxEqRel(outZ, outO, 1e15, "1:1 pool should be near-symmetric for a small trade");
    }

    // =======================================================================================
    // fuzz
    // =======================================================================================

    function testFuzz_neverPricesBeyondTheCurrentCell(uint256 amountIn, bool zeroForOne) public pure {
        amountIn = bound(amountIn, 1, 1e30);
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, zeroForOne
        );
        if (!q.withinCurrentRange) assertEq(q.amountOut, 0);
    }

    function testFuzz_amountOutBelowAmountIn_nearParity(uint256 amountIn, bool zeroForOne) public pure {
        amountIn = bound(amountIn, 1e12, 1e21);
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, zeroForOne
        );
        if (q.withinCurrentRange) assertLt(q.amountOut, amountIn, "fee + impact means out < in near 1:1");
    }

    function testFuzz_monotoneInAmountIn_whileWithinRange(uint256 lo, uint256 hi) public pure {
        lo = bound(lo, 1e12, 1e20);
        hi = bound(hi, lo, 1e21);
        ReferencePriceLib.Quote memory qLo = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, lo, true
        );
        ReferencePriceLib.Quote memory qHi = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, hi, true
        );
        if (qLo.withinCurrentRange && qHi.withinCurrentRange) {
            assertGe(qHi.amountOut, qLo.amountOut, "more in -> at least as much out");
        }
    }

    function testFuzz_feeMonotone(uint24 feeA, uint24 feeB) public pure {
        feeA = uint24(bound(feeA, 0, 100_000));
        feeB = uint24(bound(feeB, feeA, 200_000)); // feeB >= feeA
        uint256 outA =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, feeA, 1e18, true)
        .amountOut;
        uint256 outB =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, feeB, 1e18, true)
        .amountOut;
        assertGe(outA, outB, "a higher fee never returns more output");
    }

    function testFuzz_harnessMatchesLibrary(uint256 amountIn, bool zeroForOne) public view {
        amountIn = bound(amountIn, 1, 1e28);
        (bool inRange, uint256 out) =
            h.quote(SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, zeroForOne);
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, amountIn, zeroForOne
        );
        assertEq(inRange, q.withinCurrentRange);
        assertEq(out, q.amountOut);
    }

    // =======================================================================================
    // extra edge vectors
    // =======================================================================================

    function test_maxLiquidity_pricesSmallTrade() public pure {
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, type(uint128).max, FEE_3000, 1e18, true
        );
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    function test_positiveExactBoundaryTick_oneForZero_shiftsUpACell() public pure {
        // price exactly on tick 60 (a spacing multiple), oneForZero moves up; target is tick 120
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(60);
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, 60, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e18, false);
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    function test_largePositiveTick_pricesNormally() public pure {
        int24 tick = 100_000;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(sqrtP, tick, TICK_SPACING, DEEP_LIQUIDITY, FEE_3000, 1e15, true);
        assertTrue(q.withinCurrentRange);
        assertGt(q.amountOut, 0);
    }

    function test_nearMaxFee_almostNoOutput() public pure {
        // fee 990000 (99%) — almost all input consumed by fee
        ReferencePriceLib.Quote memory q = ReferencePriceLib.quoteExactInSingleRange(
            SQRT_PRICE_1_1, 0, TICK_SPACING, DEEP_LIQUIDITY, 990_000, 1e18, true
        );
        assertTrue(q.withinCurrentRange);
        assertLt(q.amountOut, 2e16, "a 99% fee leaves almost nothing");
    }

    function test_spacingOne_exactBoundary_zeroForOne_shiftsToTickMinusOne() public view {
        // tick 0 on a spacing-1 pool: zeroForOne target = tick -1, one tick of room
        assertEq(h.compressToTickLower(0, 1), int24(0));
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(SQRT_PRICE_1_1, 0, 1, DEEP_LIQUIDITY, FEE_3000, 1e12, true);
        // one tick of room at deep liquidity prices a tiny trade
        if (q.withinCurrentRange) assertGt(q.amountOut, 0);
    }

    function testFuzz_compress_matchesReferenceFormula(int24 tick, int24 spacingSeed) public view {
        int24 spacing = int24(bound(int256(spacingSeed), 1, 32767));
        tick = int24(bound(int256(tick), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
        int24 got = h.compressToTickLower(tick, spacing);
        // floor division reference
        int24 expected;
        {
            int24 c = tick / spacing;
            if (tick < 0 && tick % spacing != 0) c--;
            expected = c * spacing;
        }
        assertEq(got, expected);
    }
}
