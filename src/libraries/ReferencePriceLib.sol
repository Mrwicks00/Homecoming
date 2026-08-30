// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice Computes an exact, deterministic AMM reference price for a swap, using v4-core's own
/// audited single-step swap math (SwapMath/TickMath), bounded to the pool's current tick-spacing
/// cell so liquidity is provably constant across the whole quoted amount.
///
/// @dev Why this exists (see ARCHITECTURE_VALIDATION.md §5): v4-periphery's V4Quoter computes
/// quotes by calling `unlock()` and deliberately reverting to smuggle the result out through revert
/// data — its own authors document it as "not gas efficient" and "should not be called on-chain".
/// Nesting that inside a hook already running inside another swap's unlock() context is exactly the
/// pattern to avoid. Reading live state via StateLibrary and running ONE real SwapMath step instead
/// is cheap, safe to call mid-swap, and reuses the exact math Pool.sol itself uses per step — it does
/// not reimplement swap math from scratch.
///
/// The eligibility bound this produces (`withinCurrentRange`) is exact, not approximate: ticks can
/// only be initialized at multiples of tickSpacing, so a swap that does not move sqrtPrice past the
/// boundary of the current tick-spacing cell cannot have crossed an initialized tick, and liquidity
/// is therefore provably unchanged across the whole quoted amount.
library ReferencePriceLib {
    using SafeCast for uint256;

    struct Quote {
        // True if the full amountIn resolves without crossing the current tick-spacing cell boundary.
        // If false, this library refuses to price the trade rather than approximate across a
        // liquidity change it cannot see without a full tick-crossing loop (out of scope — see
        // ARCHITECTURE_VALIDATION.md §5). The caller must treat the swap as ineligible.
        bool withinCurrentRange;
        // Exact, fee-inclusive reference AMM output. Valid only if withinCurrentRange is true.
        uint256 amountOut;
    }

    /// @param sqrtPriceX96 Current pool sqrt price (from StateLibrary.getSlot0).
    /// @param tick Current pool tick (from StateLibrary.getSlot0).
    /// @param tickSpacing The pool's tick spacing (from the PoolKey).
    /// @param liquidity Current in-range liquidity (from StateLibrary.getLiquidity).
    /// @param lpFeePips The pool's current swap fee, in hundredths of a bip (from StateLibrary.getSlot0).
    /// @param amountIn Exact input amount to quote.
    /// @param zeroForOne Swap direction: true = currency0 in / currency1 out.
    function quoteExactInSingleRange(
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickSpacing,
        uint128 liquidity,
        uint24 lpFeePips,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (Quote memory q) {
        int24 tickLower = _compressToTickLower(tick, tickSpacing);

        uint160 sqrtPriceTargetX96;
        if (zeroForOne) {
            uint160 sqrtAtLower = TickMath.getSqrtPriceAtTick(tickLower);
            // Edge case (mirrors the boundary subtlety documented on IPoolManager.donate()): if
            // the current price sits exactly on the current cell's lower boundary already, there
            // is zero room left to move downward within that cell — the cell actually being
            // entered by a zeroForOne trade starting here is the one below it.
            sqrtPriceTargetX96 = sqrtPriceX96 == sqrtAtLower
                ? TickMath.getSqrtPriceAtTick(tickLower - tickSpacing)
                : sqrtAtLower;
        } else {
            sqrtPriceTargetX96 = TickMath.getSqrtPriceAtTick(tickLower + tickSpacing);
        }

        (uint160 sqrtPriceNextX96,, uint256 amountOut,) = SwapMath.computeSwapStep(
            sqrtPriceX96, sqrtPriceTargetX96, liquidity, -(amountIn.toInt256()), lpFeePips
        );

        // computeSwapStep caps sqrtPriceNextX96 at the target when the full amountIn would reach or
        // pass it; that means the trade cannot be safely priced within a single constant-liquidity
        // range, since we cannot see past the tick-spacing boundary without a tick-crossing loop.
        if (sqrtPriceNextX96 == sqrtPriceTargetX96) {
            q.withinCurrentRange = false;
        } else {
            q.withinCurrentRange = true;
            q.amountOut = amountOut;
        }
    }

    /// @dev Mirrors v4-core's own tick-compression convention (e.g. TickBitmap.compress): plain
    /// integer division truncates toward zero, which is wrong for negative ticks, so we floor
    /// explicitly instead.
    function _compressToTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24 tickLower) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        tickLower = compressed * tickSpacing;
    }
}
