// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPrivateVenueAdapter} from "../../src/integrations/IPrivateVenueAdapter.sol";

/// @notice An adapter that misbehaves in a configurable way, to prove HomecomingHook's
/// try/catch isolation (`attemptVenueRoute` self-call) degrades every one of these to a plain,
/// non-reverting AMM swap — never to fabricated value or a stuck trade.
///
/// Every mode ends with `attemptVenueRoute` reverting, which `_beforeSwap`'s `catch` converts to
/// `ZERO_DELTA` (plain AMM). NOT a real venue — test-only.
contract MaliciousVenueAdapter is IPrivateVenueAdapter {
    enum Mode {
        HonestBetter, // fills strictly better than reference (the "good venue" control)
        HonestWorse, // fills strictly worse than reference -> hook reverts & falls back
        RevertInSettle, // revert outright
        ReturnFalse, // return success=false, move nothing
        PayNothing, // return success=true, transfer nothing
        Underpay, // transfer (reference - 1): not strictly better -> hook reverts
        InflatedClaim, // transfer exactly reference, claim a huge number (must be ignored)
        ReenterAttemptRoute, // re-enter hook.attemptVenueRoute (OnlySelf must reject -> revert bubbles)
        ReenterGovernance // re-enter hook.setVenueAdapter (NotGovernance must reject -> revert bubbles)
    }

    Mode public mode;
    address public hook;
    mapping(bytes32 => bool) public pairEnabled;

    error Boom();
    error ReentrancyNotBlocked();

    function setMode(Mode m) external {
        mode = m;
    }

    function setHook(address h) external {
        hook = h;
    }

    function enablePair(Currency tokenIn, Currency tokenOut, bool enabled) external {
        pairEnabled[keccak256(abi.encode(tokenIn, tokenOut))] = enabled;
    }

    function fundReserves(Currency token, uint256 amount) external {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
    }

    function isAvailable(Currency tokenIn, Currency tokenOut) external view override returns (bool) {
        return pairEnabled[keccak256(abi.encode(tokenIn, tokenOut))];
    }

    function trySettle(
        Currency, /* tokenIn */
        Currency tokenOut,
        uint256, /* amountIn */
        uint256 minAmountOut,
        address recipient,
        bytes calldata venueData
    ) external override returns (bool success, uint256 amountOutClaimed) {
        uint256 ammReference = abi.decode(venueData, (uint256));
        address out = Currency.unwrap(tokenOut);

        if (mode == Mode.RevertInSettle) revert Boom();
        if (mode == Mode.ReturnFalse) return (false, 0);
        if (mode == Mode.PayNothing) return (true, ammReference * 2);

        if (mode == Mode.ReenterAttemptRoute) {
            // selector of attemptVenueRoute(PoolKey,Currency,Currency,uint256,uint256,bool) — args
            // left empty on purpose; the OnlySelf guard must reject before ABI decoding matters.
            (bool ok,) = hook.call(abi.encodeWithSelector(0x00000000));
            if (ok) revert ReentrancyNotBlocked();
            revert Boom();
        }

        if (mode == Mode.ReenterGovernance) {
            (bool ok,) = hook.call(abi.encodeWithSignature("setVenueAdapter(address)", address(0)));
            if (ok) revert ReentrancyNotBlocked();
            revert Boom();
        }

        uint256 payout;
        if (mode == Mode.HonestBetter) {
            payout = ammReference + (ammReference * 500) / 10_000; // +5%
        } else if (mode == Mode.HonestWorse) {
            payout = (ammReference * 9_500) / 10_000; // -5%
        } else if (mode == Mode.Underpay) {
            payout = ammReference == 0 ? 0 : ammReference - 1;
        } else if (mode == Mode.InflatedClaim) {
            payout = ammReference; // exactly parity -> not strictly better
        }

        require(IERC20Minimal(out).balanceOf(address(this)) >= payout, "reserves");
        if (payout > 0) IERC20Minimal(out).transfer(recipient, payout);

        amountOutClaimed = mode == Mode.InflatedClaim ? type(uint128).max : payout;
        success = payout >= minAmountOut;
        // For HonestBetter, a genuine fill; every other mode leaves realized <= reference so the
        // hook's own check reverts attemptVenueRoute and the swap falls back to plain AMM.
    }
}
