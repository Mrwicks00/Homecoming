// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ImprovementLib} from "../../src/libraries/ImprovementLib.sol";

contract ImprovementLibTest is Test {
    function test_computeImprovement_zeroWhenVenueNotBetter(uint256 ammOut, uint256 venueOut) public pure {
        venueOut = bound(venueOut, 0, ammOut);
        assertEq(ImprovementLib.computeImprovement(venueOut, ammOut), 0);
    }

    function test_computeImprovement_exactDifferenceWhenBetter(uint256 ammOut, uint256 extra) public pure {
        ammOut = bound(ammOut, 0, type(uint128).max);
        extra = bound(extra, 1, type(uint128).max);
        assertEq(ImprovementLib.computeImprovement(ammOut + extra, ammOut), extra);
    }

    /// @dev INV1 (MECHANISM.md §9): LPShare <= Improvement, always, for any inputs.
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
        assertEq(lpShare + residual, improvement, "conservation violated: lpShare + residual != Improvement");
    }

    /// @dev INV2: zero Improvement must never produce a payout.
    function testFuzz_INV2_zeroImprovementMeansZeroPayout(
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) public pure {
        (uint256 lpShare, uint256 residual) =
            ImprovementLib.splitImprovement(0, amountIn, lpRecaptureBps, maxImprovementBpsOfAmountIn);
        assertEq(lpShare, 0);
        assertEq(residual, 0);
    }

    /// @dev The LP-share basis is capped at maxImprovementBpsOfAmountIn of amountIn — a stale or
    /// manipulated reference price cannot inflate the donation beyond that bound.
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

    function test_toDonationAmounts_routesToCorrectSide() public pure {
        (uint256 a0, uint256 a1) = ImprovementLib.toDonationAmounts(100, true);
        assertEq(a0, 0);
        assertEq(a1, 100);

        (a0, a1) = ImprovementLib.toDonationAmounts(100, false);
        assertEq(a0, 100);
        assertEq(a1, 0);
    }
}
