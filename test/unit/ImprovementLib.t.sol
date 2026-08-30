// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ImprovementLib} from "../../src/libraries/ImprovementLib.sol";

/// @notice Unit + fuzz coverage for the pure Improvement / LP-split math (MECHANISM.md §6/§7/§9).
contract ImprovementLibTest is Test {
    // =======================================================================================
    // computeImprovement
    // =======================================================================================

    function test_computeImprovement_venueStrictlyBetter() public pure {
        assertEq(ImprovementLib.computeImprovement(1_050, 1_000), 50);
    }

    function test_computeImprovement_venueEqual_isZero() public pure {
        assertEq(ImprovementLib.computeImprovement(1_000, 1_000), 0);
    }

    function test_computeImprovement_venueWorse_isZero() public pure {
        assertEq(ImprovementLib.computeImprovement(999, 1_000), 0);
    }

    function test_computeImprovement_oneWeiBetter() public pure {
        assertEq(ImprovementLib.computeImprovement(1_001, 1_000), 1);
    }

    function test_computeImprovement_oneWeiWorse_isZero() public pure {
        assertEq(ImprovementLib.computeImprovement(1_000, 1_001), 0);
    }

    function test_computeImprovement_bothZero_isZero() public pure {
        assertEq(ImprovementLib.computeImprovement(0, 0), 0);
    }

    function test_computeImprovement_venueZero_ammPositive_isZero() public pure {
        assertEq(ImprovementLib.computeImprovement(0, 1_000), 0);
    }

    function test_computeImprovement_ammZero_venuePositive_isFullVenue() public pure {
        assertEq(ImprovementLib.computeImprovement(1_000, 0), 1_000);
    }

    function test_computeImprovement_maxSpread() public pure {
        assertEq(ImprovementLib.computeImprovement(type(uint256).max, 0), type(uint256).max);
    }

    function test_computeImprovement_nearMax() public pure {
        assertEq(ImprovementLib.computeImprovement(type(uint256).max, type(uint256).max - 3), 3);
    }

    function testFuzz_computeImprovement_zeroWhenVenueNotBetter(uint256 ammOut, uint256 venueOut) public pure {
        venueOut = bound(venueOut, 0, ammOut);
        assertEq(ImprovementLib.computeImprovement(venueOut, ammOut), 0);
    }

    function testFuzz_computeImprovement_exactDifferenceWhenBetter(uint256 ammOut, uint256 extra) public pure {
        ammOut = bound(ammOut, 0, type(uint128).max);
        extra = bound(extra, 1, type(uint128).max);
        assertEq(ImprovementLib.computeImprovement(ammOut + extra, ammOut), extra);
    }

    function testFuzz_computeImprovement_neverExceedsVenueOut(uint256 venueOut, uint256 ammOut) public pure {
        assertLe(ImprovementLib.computeImprovement(venueOut, ammOut), venueOut);
    }

    // =======================================================================================
    // splitImprovement — concrete
    // =======================================================================================

    function test_split_zeroImprovement_returnsZeros() public pure {
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(0, 1e18, 5000, 1000);
        assertEq(lp, 0);
        assertEq(res, 0);
    }

    function test_split_capNotBinding_halfToLp() public pure {
        // improvement 100, cap = 1e18 * 1000/1e4 = 1e17 (not binding), lpBps 5000 -> lp 50
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(100, 1e18, 5000, 1000);
        assertEq(lp, 50);
        assertEq(res, 50);
    }

    function test_split_capBinding_clampsBasis() public pure {
        // amountIn 1_000, maxBps 100 -> cap = 10. improvement 1_000 >> cap.
        // basis = 10, lpBps 5000 -> lp = 5. residual = improvement - lp = 995.
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 1_000, 5000, 100);
        assertEq(lp, 5);
        assertEq(res, 995);
        assertEq(lp + res, 1_000);
    }

    function test_split_capExactlyEqualsImprovement() public pure {
        // cap = 1_000 * 1000/1e4 = 100; improvement exactly 100 -> basis 100, lp 50
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(100, 1_000, 5000, 1000);
        assertEq(lp, 50);
        assertEq(res, 50);
    }

    function test_split_lpRecaptureBpsZero_noLpShare() public pure {
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 1e18, 0, 1000);
        assertEq(lp, 0);
        assertEq(res, 1_000);
    }

    function test_split_lpRecaptureBpsFull_allBasisToLp() public pure {
        // cap not binding: basis == improvement, lpBps 10000 -> lp == improvement
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 1e18, 10_000, 1000);
        assertEq(lp, 1_000);
        assertEq(res, 0);
    }

    function test_split_lpRecaptureBpsFull_capBinding() public pure {
        // amountIn 1_000, maxBps 100 -> cap 10; lpBps 10000 -> lp 10, residual 990
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 1_000, 10_000, 100);
        assertEq(lp, 10);
        assertEq(res, 990);
    }

    function test_split_maxImprovementBpsZero_capIsZero_noLpShare() public pure {
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 1e18, 5000, 0);
        assertEq(lp, 0);
        assertEq(res, 1_000);
    }

    function test_split_amountInZero_capIsZero_noLpShare() public pure {
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000, 0, 5000, 1000);
        assertEq(lp, 0);
        assertEq(res, 1_000);
    }

    function test_split_roundsDown_dustToResidual() public pure {
        // basis 3 (improvement below cap), lpBps 5000 -> 3*5000/1e4 = 1 (1.5 floored). residual 2.
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(3, 1e18, 5000, 1000);
        assertEq(lp, 1);
        assertEq(res, 2);
        assertEq(lp + res, 3);
    }

    function test_split_roundsDown_belowOne_lpZero() public pure {
        // basis 1, lpBps 5000 -> 0. residual keeps the whole unit.
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1, 1e18, 5000, 1000);
        assertEq(lp, 0);
        assertEq(res, 1);
    }

    function test_split_conservation_alwaysHolds_concrete() public pure {
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(777_777, 1234e15, 3333, 777);
        assertEq(lp + res, 777_777);
    }

    function test_split_residualNeverBelowNonLpImprovement() public pure {
        // With cap binding, residual = improvement - lp, i.e. everything above the LP cut,
        // including the entire above-cap remainder.
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1_000_000, 1_000, 5000, 100);
        // cap = 10, basis = 10, lp = 5
        assertEq(lp, 5);
        assertEq(res, 999_995);
    }

    // =======================================================================================
    // splitImprovement — fuzz / invariants (MECHANISM.md §9)
    // =======================================================================================

    /// @dev INV1: lpShare <= Improvement, always. And exact conservation.
    function testFuzz_INV1_lpShareNeverExceedsImprovement(
        uint256 improvement,
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) public pure {
        improvement = bound(improvement, 0, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);
        lpRecaptureBps = uint16(bound(lpRecaptureBps, 0, 10_000));
        maxImprovementBpsOfAmountIn = uint16(bound(maxImprovementBpsOfAmountIn, 0, 10_000));

        (uint256 lpShare, uint256 residual) =
            ImprovementLib.splitImprovement(improvement, amountIn, lpRecaptureBps, maxImprovementBpsOfAmountIn);

        assertLe(lpShare, improvement, "INV1 violated: lpShare > Improvement");
        assertEq(lpShare + residual, improvement, "conservation violated");
    }

    /// @dev INV2: zero Improvement -> zero payout, no matter the params.
    function testFuzz_INV2_zeroImprovementMeansZeroPayout(
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) public pure {
        (uint256 lpShare, uint256 residual) = ImprovementLib.splitImprovement(
            0, amountIn, lpRecaptureBps, maxImprovementBpsOfAmountIn
        );
        assertEq(lpShare, 0);
        assertEq(residual, 0);
    }

    /// @dev The LP-share basis is capped at maxImprovementBpsOfAmountIn of amountIn.
    function testFuzz_lpShareBoundedByCapOfAmountIn(
        uint256 improvement,
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) public pure {
        improvement = bound(improvement, 0, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);
        lpRecaptureBps = uint16(bound(lpRecaptureBps, 0, 10_000));
        maxImprovementBpsOfAmountIn = uint16(bound(maxImprovementBpsOfAmountIn, 0, 10_000));

        (uint256 lpShare,) =
            ImprovementLib.splitImprovement(improvement, amountIn, lpRecaptureBps, maxImprovementBpsOfAmountIn);

        uint256 maxPossibleLpShare = (amountIn * maxImprovementBpsOfAmountIn / 10_000) * lpRecaptureBps / 10_000;
        assertLe(lpShare, maxPossibleLpShare, "lpShare exceeded the amountIn-relative cap");
    }

    /// @dev lpShare also never exceeds `improvement * lpRecaptureBps / 10_000` (the uncapped cut).
    function testFuzz_lpShareBoundedByUncappedCut(
        uint256 improvement,
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) public pure {
        improvement = bound(improvement, 0, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);
        lpRecaptureBps = uint16(bound(lpRecaptureBps, 0, 10_000));
        maxImprovementBpsOfAmountIn = uint16(bound(maxImprovementBpsOfAmountIn, 0, 10_000));

        (uint256 lpShare,) =
            ImprovementLib.splitImprovement(improvement, amountIn, lpRecaptureBps, maxImprovementBpsOfAmountIn);
        assertLe(lpShare, improvement * lpRecaptureBps / 10_000 + 1);
    }

    /// @dev Monotonic: a larger improvement never yields a smaller lpShare (params fixed).
    function testFuzz_lpShareMonotoneInImprovement(uint256 lo, uint256 hi, uint256 amountIn) public pure {
        lo = bound(lo, 0, type(uint96).max);
        hi = bound(hi, lo, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);

        (uint256 lpLo,) = ImprovementLib.splitImprovement(lo, amountIn, 5000, 1000);
        (uint256 lpHi,) = ImprovementLib.splitImprovement(hi, amountIn, 5000, 1000);
        assertGe(lpHi, lpLo);
    }

    /// @dev Monotonic in amountIn: a larger trade never shrinks the cap, so never shrinks lpShare.
    function testFuzz_lpShareMonotoneInAmountIn(uint256 improvement, uint256 aLo, uint256 aHi) public pure {
        improvement = bound(improvement, 0, type(uint128).max);
        aLo = bound(aLo, 0, type(uint96).max);
        aHi = bound(aHi, aLo, type(uint128).max);

        (uint256 lpLo,) = ImprovementLib.splitImprovement(improvement, aLo, 5000, 1000);
        (uint256 lpHi,) = ImprovementLib.splitImprovement(improvement, aHi, 5000, 1000);
        assertGe(lpHi, lpLo);
    }

    // =======================================================================================
    // toDonationAmounts
    // =======================================================================================

    function test_toDonationAmounts_zeroForOne_routesToToken1() public pure {
        (uint256 a0, uint256 a1) = ImprovementLib.toDonationAmounts(100, true);
        assertEq(a0, 0);
        assertEq(a1, 100);
    }

    function test_toDonationAmounts_oneForZero_routesToToken0() public pure {
        (uint256 a0, uint256 a1) = ImprovementLib.toDonationAmounts(100, false);
        assertEq(a0, 100);
        assertEq(a1, 0);
    }

    function test_toDonationAmounts_zero_bothSidesZero() public pure {
        (uint256 a0, uint256 a1) = ImprovementLib.toDonationAmounts(0, true);
        assertEq(a0, 0);
        assertEq(a1, 0);
        (a0, a1) = ImprovementLib.toDonationAmounts(0, false);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function testFuzz_toDonationAmounts_onlyOneSideEverNonzero(uint256 lpShare, bool zeroForOne) public pure {
        (uint256 a0, uint256 a1) = ImprovementLib.toDonationAmounts(lpShare, zeroForOne);
        assertEq(a0 + a1, lpShare);
        assertTrue(a0 == 0 || a1 == 0);
        if (zeroForOne) assertEq(a1, lpShare);
        else assertEq(a0, lpShare);
    }

    // =======================================================================================
    // extra edge vectors
    // =======================================================================================

    function test_split_hugeImprovement_capBinds_noOverflow() public pure {
        // amountIn near uint128 max, maxBps 10000 -> cap ~= amountIn. improvement = uint128 max.
        uint256 amountIn = type(uint128).max;
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(type(uint128).max, amountIn, 10_000, 10_000);
        assertEq(lp + res, type(uint128).max);
        assertLe(lp, type(uint128).max);
    }

    function test_split_capLargerThanImprovement_usesImprovement() public pure {
        // amountIn 1e24, maxBps 10000 -> cap 1e24; improvement 1e18 < cap -> basis = 1e18
        (uint256 lp,) = ImprovementLib.splitImprovement(1e18, 1e24, 5000, 10_000);
        assertEq(lp, 5e17);
    }

    function test_split_oneBps_recaptureRate() public pure {
        // basis 1e18 (below cap), lpBps 1 -> 1e18 * 1 / 1e4 = 1e14
        (uint256 lp,) = ImprovementLib.splitImprovement(1e18, 1e24, 1, 10_000);
        assertEq(lp, 1e14);
    }

    function test_split_capIsOneWei() public pure {
        // amountIn 10000, maxBps 1 -> cap = 1. improvement 1e18 -> basis 1. lpBps 10000 -> lp 1.
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(1e18, 10_000, 10_000, 1);
        assertEq(lp, 1);
        assertEq(res, 1e18 - 1);
    }

    function testFuzz_residualAlwaysAtLeastImprovementMinusCappedCut(
        uint256 improvement,
        uint256 amountIn,
        uint16 lpBps,
        uint16 maxBps
    ) public pure {
        improvement = bound(improvement, 0, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);
        lpBps = uint16(bound(lpBps, 0, 10_000));
        maxBps = uint16(bound(maxBps, 0, 10_000));
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(improvement, amountIn, lpBps, maxBps);
        // residual holds everything not given to LPs, including all above-cap Improvement
        assertGe(res, improvement - lp);
        assertEq(res, improvement - lp);
    }

    function testFuzz_computeThenSplit_composed(uint256 venueOut, uint256 ammOut, uint256 amountIn) public pure {
        venueOut = bound(venueOut, 0, type(uint128).max);
        ammOut = bound(ammOut, 0, type(uint128).max);
        amountIn = bound(amountIn, 0, type(uint128).max);
        uint256 imp = ImprovementLib.computeImprovement(venueOut, ammOut);
        (uint256 lp, uint256 res) = ImprovementLib.splitImprovement(imp, amountIn, 5000, 1000);
        assertEq(lp + res, imp);
        if (venueOut <= ammOut) {
            assertEq(lp, 0);
            assertEq(res, 0);
        }
    }
}
