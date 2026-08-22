// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice A private-venue adapter capable of SYNCHRONOUS, same-transaction settlement.
///
/// @dev This is deliberately narrow. FEASIBILITY.md establishes that neither CoW Protocol (async,
/// off-chain-solved) nor Flashbots Protect (not a settlement venue at all) can implement this
/// interface for real — this interface describes what a hypothetical same-chain synchronous
/// counterparty (e.g. an on-chain RFQ market maker) WOULD need to provide for HomecomingHook's
/// beforeSwap-time NoOp routing to be real. On Unichain Sepolia, the only concrete implementation
/// shipped is MockVenueAdapter, used in tests/demo and clearly labeled as a mock — see MECHANISM.md
/// §0/§4 and README.md for why no real adapter is configured in the live deployment.
///
/// The real CoW integration lives entirely outside this interface, in the CoW-post-hook receiver
/// (src/integrations/cow/), which is architecturally inverted: CoW settlement calls INTO the pool,
/// not the other way around. See MECHANISM.md §5.
interface IPrivateVenueAdapter {
    /// @notice View-only, no-funds-moved check of whether this adapter could attempt to settle
    /// this pair right now. A true return is not a guarantee — `trySettle` may still fail or
    /// underperform, and the caller must independently verify the realized fill regardless.
    function isAvailable(Currency tokenIn, Currency tokenOut) external view returns (bool);

    /// @notice Attempt synchronous settlement: the caller has already transferred `amountIn` of
    /// `tokenIn` to this adapter before calling. On success the adapter MUST have transferred at
    /// least `minAmountOut` of `tokenOut` to `recipient` before returning.
    /// @dev The caller (HomecomingHook) never trusts `amountOutClaimed` alone — it independently
    /// measures `tokenOut.balanceOf(recipient)` before and after this call and uses the realized
    /// delta for all Improvement/LP-recapture accounting. An adapter is free to revert instead of
    /// returning `success = false`; the caller treats both identically (a failed venue attempt),
    /// via a self-call try/catch that rolls back any partial state and falls back to the AMM.
    /// @return success True if the adapter believes it settled at least `minAmountOut`.
    /// @return amountOutClaimed The adapter's own claimed output amount — advisory only.
    function trySettle(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata venueData
    ) external returns (bool success, uint256 amountOutClaimed);
}
