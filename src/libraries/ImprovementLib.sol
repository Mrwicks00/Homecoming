// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Formal Improvement/LP-split math. Pure functions only — no state, no external calls,
/// no trust in caller-supplied "venue output" numbers (callers must pass already-verified,
/// realized amounts — see MECHANISM.md §6/§8).
library ImprovementLib {
    /// @notice Improvement = realized venue output - exact AMM reference output, for the same
    /// input, same pair, fee-inclusive on both sides. Never negative — a worse or equal venue
    /// fill yields zero Improvement, never a "loss" to account for.
    function computeImprovement(uint256 venueAmountOut, uint256 ammAmountOut) internal pure returns (uint256) {
        if (venueAmountOut <= ammAmountOut) return 0;
        unchecked {
            return venueAmountOut - ammAmountOut;
        }
    }

    /// @notice Splits Improvement between LPs and the trader/venue side.
    /// @dev The LP-share basis is capped at `maxImprovementBpsOfAmountIn` of amountIn so a stale or
    /// manipulated reference price cannot inflate the donation beyond a sane bound relative to trade
    /// size (defense in depth on top of EligibilityLib's exactness guarantee). Anything above the cap
    /// flows entirely to the trader/venue side, never to an inflated LP share. Both divisions round
    /// down; the LP side never benefits from rounding at the trader/venue side's expense, and vice
    /// versa — dust always remains with the trader/venue share.
    /// @return lpShare Amount of the output token donated to in-range LPs.
    /// @return residual Amount of Improvement retained by the trader/venue side.
    function splitImprovement(
        uint256 improvement,
        uint256 amountIn,
        uint16 lpRecaptureBps,
        uint16 maxImprovementBpsOfAmountIn
    ) internal pure returns (uint256 lpShare, uint256 residual) {
        if (improvement == 0) return (0, 0);

        uint256 cap = (amountIn * maxImprovementBpsOfAmountIn) / 10_000;
        uint256 basis = improvement > cap ? cap : improvement;

        lpShare = (basis * lpRecaptureBps) / 10_000;
        residual = improvement - lpShare;
    }

    /// @notice Maps a single-token LP share (denominated in the swap's output token) onto the two
    /// amounts PoolManager.donate() expects.
    function toDonationAmounts(uint256 lpShareOut, bool zeroForOne)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        // zeroForOne: token0 in, token1 out -> the improvement is realized in token1.
        if (zeroForOne) {
            amount1 = lpShareOut;
        } else {
            amount0 = lpShareOut;
        }
    }
}
