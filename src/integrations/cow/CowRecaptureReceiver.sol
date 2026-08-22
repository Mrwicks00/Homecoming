// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {HomecomingTypes} from "../../libraries/HomecomingTypes.sol";
import {ReferencePriceLib} from "../../libraries/ReferencePriceLib.sol";
import {ImprovementLib} from "../../libraries/ImprovementLib.sol";
import {CurrencySettleLib} from "../../libraries/CurrencySettleLib.sol";

/// @title CowRecaptureReceiver — Homecoming's real CoW Protocol leg (Ethereum Sepolia)
///
/// @notice The ONE genuinely real private-venue integration in this project (FEASIBILITY.md §1).
/// It is deliberately NOT a "hook that routes to CoW" — that architecture is impossible (see
/// FEASIBILITY.md). Instead, control flows the other way: a trader's CoW order names this contract
/// as a post-hook target (executed atomically inside the winning solver's `GPv2Settlement.settle()`
/// transaction, via CoW's `HooksTrampoline` — see MECHANISM.md §5). The trader's swap settles
/// entirely normally through CoW; the trader receives their real output directly in their own
/// wallet. This contract never custodies a trader's trade proceeds.
///
/// @dev TRUST MODEL — read before assuming this behaves like HomecomingHook's Core leg:
///
/// HomecomingHook (Core) observes a swap's real `amountIn` directly from `SwapParams`, trustlessly.
/// This receiver has no equivalent privileged view into a CoW order's real sell/buy amounts — a
/// post-hook's `callData` is chosen by whoever created the order (the trader), and CoW's own docs
/// state plainly that a call arriving via the trampoline must not be assumed to carry trustworthy
/// context (see FEASIBILITY.md Q12 sources). So `amountInClaimed` and `venueAmountOutClaimed` below
/// are BOTH self-reported by the trader, not independently verified.
///
/// This is why the design is pull-based rather than custody-based: `recapture()` never disburses
/// funds to a caller-chosen recipient, and never pulls more than the trader has themselves
/// pre-approved via a standard ERC20 `approve()`. The only thing a dishonest trader can achieve by
/// misreporting is UNDER-stating their own Improvement to shrink their own LP contribution — there
/// is no reported-number path that lets a caller extract funds from anyone but the named `trader`,
/// bounded by that trader's own allowance, paid only to the pool via `donate()`. A first draft of
/// this contract held trade proceeds in a shared contract balance with a caller-chosen recipient;
/// that is a real theft vector (any caller could sweep another order's settled balance to
/// themselves) and was rejected during design — see MECHANISM.md addendum.
///
/// Net effect: the CoW leg's recapture is consent-based, not fully trustless. A trader who never
/// approves this contract, or approves nothing, simply never contributes — the mechanism cannot
/// force them to. What it cannot ever do is take more than that trader explicitly allowed, or take
/// from anyone else. This is a materially different, weaker trust bar than the Core leg, and is
/// documented as such rather than glossed over (see brief §40's claim-discipline requirement).
contract CowRecaptureReceiver is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public governance;
    HomecomingTypes.Config public config;

    event Recaptured(
        PoolId indexed poolId,
        address indexed trader,
        uint256 amountInClaimed,
        uint256 venueAmountOutClaimed,
        uint256 ammAmountOut,
        uint256 lpShare
    );
    event RecaptureSkipped(address indexed trader, bytes32 reason);

    error NotGovernance();
    error NotPoolManager();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(IPoolManager _poolManager, HomecomingTypes.Config memory _config, address _governance) {
        poolManager = _poolManager;
        config = _config;
        governance = _governance;
    }

    function setConfig(HomecomingTypes.Config calldata newConfig) external onlyGovernance {
        config = newConfig;
    }

    /// @notice Intended as a CoW order post-hook target. Permissionless by design — see the
    /// contract-level trust-model NatSpec for exactly why that is safe: every payout is either to
    /// the pool (via donate) or bounded by the named trader's own pre-approved allowance.
    /// @param key The Homecoming-tracked pool this trade's Improvement is measured against.
    /// @param zeroForOne True if the trader sold currency0 for currency1.
    /// @param trader The trader whose order this claims to follow up on; funds are pulled ONLY
    /// from this address, and only up to what it has approved this contract to spend.
    /// @param amountInClaimed Self-reported sell amount — see trust-model NatSpec.
    /// @param venueAmountOutClaimed Self-reported realized CoW buy amount — see trust-model NatSpec.
    function recapture(
        PoolKey calldata key,
        bool zeroForOne,
        address trader,
        uint256 amountInClaimed,
        uint256 venueAmountOutClaimed
    ) external {
        PoolId poolId = key.toId();

        if (amountInClaimed == 0 || venueAmountOutClaimed == 0) {
            emit RecaptureSkipped(trader, "zero_claim");
            return;
        }

        Currency tokenOut = zeroForOne ? key.currency1 : key.currency0;

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        ReferencePriceLib.Quote memory quote = ReferencePriceLib.quoteExactInSingleRange(
            sqrtPriceX96, tick, key.tickSpacing, liquidity, lpFee, amountInClaimed, zeroForOne
        );
        if (!quote.withinCurrentRange) {
            emit RecaptureSkipped(trader, "outside_current_range");
            return;
        }

        uint256 improvement = ImprovementLib.computeImprovement(venueAmountOutClaimed, quote.amountOut);
        (uint256 lpShare,) = ImprovementLib.splitImprovement(
            improvement, amountInClaimed, config.lpRecaptureBps, config.maxImprovementBpsOfAmountIn
        );

        if (lpShare == 0) {
            emit RecaptureSkipped(trader, "no_improvement");
            return;
        }

        // Bounded entirely by the trader's own pre-approved allowance; touches no other balance.
        IERC20Minimal(Currency.unwrap(tokenOut)).transferFrom(trader, address(this), lpShare);

        (uint256 amount0, uint256 amount1) = ImprovementLib.toDonationAmounts(lpShare, zeroForOne);
        poolManager.unlock(abi.encode(key, tokenOut, amount0, amount1));

        emit Recaptured(poolId, trader, amountInClaimed, venueAmountOutClaimed, quote.amountOut, lpShare);
    }

    /// @dev This is a FRESH unlock() — unlike HomecomingHook's afterSwap-context donate, this leg
    /// never runs inside an existing swap's lock (see MECHANISM.md §5), so it must open its own.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory key, Currency tokenOut, uint256 amount0, uint256 amount1) =
            abi.decode(data, (PoolKey, Currency, uint256, uint256));

        poolManager.donate(key, amount0, amount1, "");
        uint256 amt = amount0 > 0 ? amount0 : amount1;
        CurrencySettleLib.settle(tokenOut, poolManager, address(this), amt);
        return "";
    }
}
