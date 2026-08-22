// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared configuration and result types for the Homecoming mechanism.
/// @dev Pure data types only — no logic. See MECHANISM.md for the formulas that consume these.
library HomecomingTypes {
    /// @notice Deployment-time eligibility and recapture policy.
    /// @param minAmountIn Minimum input amount (in the input token's own decimals) to be eligible for routing.
    /// @param minLiquidity Minimum in-range pool liquidity required for eligibility.
    /// @param lpRecaptureBps Share of realized Improvement paid to in-range LPs, in basis points (of 10_000).
    /// @param maxImprovementBpsOfAmountIn Caps the Improvement basis used for the LP split, expressed as
    ///        basis points of amountIn, so a stale or manipulated reference price cannot inflate the donation.
    struct Config {
        uint256 minAmountIn;
        uint128 minLiquidity;
        uint16 lpRecaptureBps;
        uint16 maxImprovementBpsOfAmountIn;
    }

    /// @notice Result of comparing a swap's eligibility against current pool state.
    /// @param sizeEligible True if amountIn/liquidity/pair thresholds are met.
    /// @param withinCurrentRange True if the trade resolves without crossing the pool's current
    ///        tick-spacing cell (see ReferencePriceLib) — required for the reference price to be exact.
    /// @param ammAmountOut The exact, fee-inclusive reference AMM output for amountIn, valid only if
    ///        withinCurrentRange is true.
    struct Eligibility {
        bool sizeEligible;
        bool withinCurrentRange;
        uint256 ammAmountOut;
    }
}
