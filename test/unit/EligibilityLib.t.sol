// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EligibilityLib} from "../../src/libraries/EligibilityLib.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";

/// @notice Unit coverage for EligibilityLib — the objective, deterministic routing policy
/// (MECHANISM.md §3). It never claims to know trader intent; it only decides whether a trade is
/// small enough, against enough liquidity, to be priced exactly by ReferencePriceLib.
contract EligibilityLibTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_3000 = 3000;
    uint128 constant DEEP_LIQUIDITY = 1e24;

    function _cfg(uint256 minAmountIn, uint128 minLiquidity) internal pure returns (HomecomingTypes.Config memory) {
        return HomecomingTypes.Config({
            minAmountIn: minAmountIn,
            minLiquidity: minLiquidity,
            lpRecaptureBps: 5000,
            maxImprovementBpsOfAmountIn: 1000
        });
    }

    function _eval(HomecomingTypes.Config memory cfg, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (HomecomingTypes.Eligibility memory)
    {
        return EligibilityLib.evaluate(
            cfg, SQRT_PRICE_1_1, int24(0), TICK_SPACING, liquidity, FEE_3000, amountIn, zeroForOne
        );
    }

    // ---------------------------------------------------------------------------------------
    // size threshold: minAmountIn
    // ---------------------------------------------------------------------------------------

    function test_belowMinAmountIn_notSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e18, 0), DEEP_LIQUIDITY, 1e18 - 1, true);
        assertFalse(e.sizeEligible);
        assertFalse(EligibilityLib.isEligible(e));
    }

    function test_exactlyMinAmountIn_isSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e18, 0), DEEP_LIQUIDITY, 1e18, true);
        assertTrue(e.sizeEligible);
    }

    function test_aboveMinAmountIn_isSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, true);
        assertTrue(e.sizeEligible);
    }

    // ---------------------------------------------------------------------------------------
    // size threshold: minLiquidity
    // ---------------------------------------------------------------------------------------

    function test_belowMinLiquidity_notSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 1e24), 1e24 - 1, 1e18, true);
        assertFalse(e.sizeEligible);
        assertFalse(EligibilityLib.isEligible(e));
    }

    function test_exactlyMinLiquidity_isSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 1e24), 1e24, 1e18, true);
        assertTrue(e.sizeEligible);
    }

    function test_aboveMinLiquidity_isSizeEligible() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 1e12), DEEP_LIQUIDITY, 1e18, true);
        assertTrue(e.sizeEligible);
    }

    function test_minLiquidityZero_alwaysPassesLiquidityGate() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), 1, 1e18, true);
        assertTrue(e.sizeEligible);
    }

    // ---------------------------------------------------------------------------------------
    // short-circuit: not size-eligible => no quote work, ammAmountOut stays 0
    // ---------------------------------------------------------------------------------------

    function test_notSizeEligible_leavesRangeAndQuoteAtDefault() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e30, 0), DEEP_LIQUIDITY, 1e18, true);
        assertFalse(e.sizeEligible);
        assertFalse(e.withinCurrentRange);
        assertEq(e.ammAmountOut, 0);
    }

    function test_notSizeEligible_dueToLiquidity_leavesQuoteAtDefault() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, type(uint128).max), DEEP_LIQUIDITY, 1e18, true);
        assertFalse(e.sizeEligible);
        assertEq(e.ammAmountOut, 0);
    }

    // ---------------------------------------------------------------------------------------
    // quote propagation
    // ---------------------------------------------------------------------------------------

    function test_sizeEligibleAndInRange_populatesQuote_zeroForOne() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, true);
        assertTrue(e.sizeEligible);
        assertTrue(e.withinCurrentRange);
        assertGt(e.ammAmountOut, 0);
        assertLt(e.ammAmountOut, 1e18, "fee-inclusive output is below amountIn");
    }

    function test_sizeEligibleAndInRange_populatesQuote_oneForZero() public pure {
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, false);
        assertTrue(e.withinCurrentRange);
        assertGt(e.ammAmountOut, 0);
    }

    function test_sizeEligibleButOversized_notInRange_quoteZero() public pure {
        // Huge trade against thin liquidity: priced as NOT within the current cell.
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), 1e12, 1e18, true);
        assertTrue(e.sizeEligible);
        assertFalse(e.withinCurrentRange);
        assertEq(e.ammAmountOut, 0);
        assertFalse(EligibilityLib.isEligible(e));
    }

    // ---------------------------------------------------------------------------------------
    // isEligible truth table
    // ---------------------------------------------------------------------------------------

    function test_isEligible_truthTable() public pure {
        // 1) size ok + in range -> eligible
        assertTrue(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, true)));
        // 2) size ok + not in range -> not eligible
        assertFalse(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), 1e12, 1e18, true)));
        // 3) not size ok (in-range would be true) -> not eligible
        assertFalse(EligibilityLib.isEligible(_eval(_cfg(1e30, 0), DEEP_LIQUIDITY, 1e18, true)));
        // 4) not size ok + not in range -> not eligible
        assertFalse(EligibilityLib.isEligible(_eval(_cfg(1e30, 0), 1e12, 1e18, true)));
    }

    function test_isEligible_pureFunctionOfStruct() public pure {
        HomecomingTypes.Eligibility memory a = HomecomingTypes.Eligibility(true, true, 1);
        HomecomingTypes.Eligibility memory b = HomecomingTypes.Eligibility(true, false, 1);
        HomecomingTypes.Eligibility memory c = HomecomingTypes.Eligibility(false, true, 1);
        HomecomingTypes.Eligibility memory d = HomecomingTypes.Eligibility(false, false, 0);
        assertTrue(EligibilityLib.isEligible(a));
        assertFalse(EligibilityLib.isEligible(b));
        assertFalse(EligibilityLib.isEligible(c));
        assertFalse(EligibilityLib.isEligible(d));
    }

    // ---------------------------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------------------------

    function testFuzz_sizeEligibility_matchesThresholds(
        uint256 minAmountIn,
        uint128 minLiquidity,
        uint256 amountIn,
        uint128 liquidity
    ) public pure {
        minAmountIn = bound(minAmountIn, 0, 1e30);
        amountIn = bound(amountIn, 0, 1e30);
        HomecomingTypes.Config memory cfg = _cfg(minAmountIn, minLiquidity);
        HomecomingTypes.Eligibility memory e = _eval(cfg, liquidity, amountIn, true);
        assertEq(e.sizeEligible, amountIn >= minAmountIn && liquidity >= minLiquidity);
    }

    function testFuzz_notSizeEligible_impliesNotEligibleAndZeroQuote(
        uint256 minAmountIn,
        uint256 amountIn,
        uint128 liquidity
    ) public pure {
        minAmountIn = bound(minAmountIn, 1, 1e30);
        amountIn = bound(amountIn, 0, minAmountIn - 1); // strictly below the floor
        HomecomingTypes.Eligibility memory e = _eval(_cfg(minAmountIn, 0), liquidity, amountIn, true);
        assertFalse(e.sizeEligible);
        assertFalse(EligibilityLib.isEligible(e));
        assertEq(e.ammAmountOut, 0);
    }

    function testFuzz_sizeEligibleMonotoneInAmountIn(uint256 a, uint256 b) public pure {
        a = bound(a, 1e15, 1e28);
        b = bound(b, a, 1e30); // b >= a
        HomecomingTypes.Config memory cfg = _cfg(1e18, 0);
        bool eaSize = _eval(cfg, DEEP_LIQUIDITY, a, true).sizeEligible;
        bool ebSize = _eval(cfg, DEEP_LIQUIDITY, b, true).sizeEligible;
        if (eaSize) assertTrue(ebSize, "a larger amountIn cannot become size-ineligible");
    }

    function testFuzz_eligible_impliesPositiveQuote(uint256 amountIn) public pure {
        amountIn = bound(amountIn, 1e15, 5e21);
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), DEEP_LIQUIDITY, amountIn, true);
        if (EligibilityLib.isEligible(e)) assertGt(e.ammAmountOut, 0);
    }

    // ---------------------------------------------------------------------------------------
    // direction + tick + spacing coverage
    // ---------------------------------------------------------------------------------------

    function _evalAt(
        HomecomingTypes.Config memory cfg,
        uint160 sqrtPriceX96,
        int24 tick,
        int24 spacing,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (HomecomingTypes.Eligibility memory) {
        return EligibilityLib.evaluate(cfg, sqrtPriceX96, tick, spacing, liquidity, FEE_3000, amountIn, zeroForOne);
    }

    function test_bothDirections_eligibleForSmallTrade() public pure {
        assertTrue(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, true)));
        assertTrue(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), DEEP_LIQUIDITY, 1e18, false)));
    }

    function test_oversizedTrade_bothDirections_ineligible() public pure {
        assertFalse(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), 1e12, 1e18, true)));
        assertFalse(EligibilityLib.isEligible(_eval(_cfg(1e15, 0), 1e12, 1e18, false)));
    }

    function test_negativeCurrentTick_pricesASmallTrade() public pure {
        int24 tick = -600;
        HomecomingTypes.Eligibility memory e =
            _evalAt(_cfg(1e15, 0), TickMath.getSqrtPriceAtTick(tick), tick, int24(60), DEEP_LIQUIDITY, 1e18, true);
        assertTrue(e.sizeEligible);
        assertTrue(e.withinCurrentRange);
        assertGt(e.ammAmountOut, 0);
    }

    function test_tightSpacing_shrinksEligibleSize() public pure {
        // spacing 1 refuses a mid trade that spacing 200 accepts
        bool tight = _evalAt(_cfg(1e15, 0), SQRT_PRICE_1_1, 0, 1, DEEP_LIQUIDITY, 1e21, true).withinCurrentRange;
        bool wide = _evalAt(_cfg(1e15, 0), SQRT_PRICE_1_1, 0, 200, DEEP_LIQUIDITY, 1e21, true).withinCurrentRange;
        assertFalse(tight);
        assertTrue(wide);
    }

    function testFuzz_isEligible_impliesBothFlags(uint256 amountIn, uint128 liquidity) public pure {
        amountIn = bound(amountIn, 1, 1e28);
        HomecomingTypes.Eligibility memory e = _eval(_cfg(1e15, 0), liquidity, amountIn, true);
        if (EligibilityLib.isEligible(e)) {
            assertTrue(e.sizeEligible);
            assertTrue(e.withinCurrentRange);
        }
    }

    function testFuzz_evaluate_neverReverts(uint256 amountIn, uint128 liquidity, bool zeroForOne, uint16 lpBps)
        public
        pure
    {
        amountIn = bound(amountIn, 0, type(uint128).max);
        HomecomingTypes.Config memory cfg = HomecomingTypes.Config({
            minAmountIn: 1e15, minLiquidity: 0, lpRecaptureBps: lpBps, maxImprovementBpsOfAmountIn: 1000
        });
        EligibilityLib.evaluate(cfg, SQRT_PRICE_1_1, int24(0), TICK_SPACING, liquidity, FEE_3000, amountIn, zeroForOne);
    }
}
