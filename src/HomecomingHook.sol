// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {HomecomingTypes} from "./libraries/HomecomingTypes.sol";
import {EligibilityLib} from "./libraries/EligibilityLib.sol";
import {ImprovementLib} from "./libraries/ImprovementLib.sol";
import {CurrencySettleLib} from "./libraries/CurrencySettleLib.sol";
import {IPrivateVenueAdapter} from "./integrations/IPrivateVenueAdapter.sol";

/// @title HomecomingHook — Homecoming Core (Unichain Sepolia deployment)
///
/// @notice Real, v4-native eligibility + exact single-tick AMM reference pricing + venue-routing
/// scaffold + LP recapture via donate(), with plain AMM execution as the unconditional floor.
///
/// @dev HONESTY NOTE (see FEASIBILITY.md, MECHANISM.md §0/§4): on the deployed Unichain Sepolia
/// instance, no venue adapter satisfying `IPrivateVenueAdapter`'s synchronous-settlement contract
/// exists in reality — neither CoW Protocol (async, off-chain-solved, no canonical Unichain
/// deployment) nor Flashbots Protect (not a settlement venue) can implement it. `venueAdapter`
/// therefore defaults to address(0) in production, meaning EVERY real swap here takes the plain
/// AMM path — identical to a hook-less pool. The venue-routing branch below is real, tested code,
/// exercised end-to-end only against `MockVenueAdapter` in tests/demo, clearly labeled as a mock.
/// The genuinely real venue integration is the separate CoW-post-hook leg on Ethereum Sepolia
/// (src/integrations/cow/), which is architecturally inverted (CoW settlement pays the pool; this
/// hook is never involved in that leg at all).
///
/// Scope (MECHANISM.md §2): exact-input, single-hop swaps only, and only pairs where neither
/// currency is native (native-ETH flash-accounting adds a whole additional class of edge cases
/// out of scope for the hackathon build — see README.md limitations).
contract HomecomingHook is BaseHook {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    HomecomingTypes.Config public config;

    /// @notice address(0) = no venue configured; every swap takes the plain AMM path.
    IPrivateVenueAdapter public venueAdapter;

    address public governance;

    event VenueRouted(
        PoolId indexed poolId,
        address indexed trader,
        uint256 amountIn,
        uint256 ammAmountOut,
        uint256 venueAmountOut,
        uint256 lpShare,
        uint256 traderShare
    );
    event VenueSkipped(PoolId indexed poolId, bytes32 reason);
    event ConfigUpdated(uint256 minAmountIn, uint128 minLiquidity, uint16 lpRecaptureBps, uint16 maxImprovementBpsOfAmountIn);
    event VenueAdapterUpdated(address adapter);

    error NotGovernance();
    error VenueSettlementFailed();
    error OnlySelf();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(IPoolManager _poolManager, HomecomingTypes.Config memory _config, address _governance)
        BaseHook(_poolManager)
    {
        config = _config;
        governance = _governance;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setVenueAdapter(address adapter) external onlyGovernance {
        venueAdapter = IPrivateVenueAdapter(adapter);
        emit VenueAdapterUpdated(adapter);
    }

    function setConfig(HomecomingTypes.Config calldata newConfig) external onlyGovernance {
        config = newConfig;
        emit ConfigUpdated(
            newConfig.minAmountIn, newConfig.minLiquidity, newConfig.lpRecaptureBps, newConfig.maxImprovementBpsOfAmountIn
        );
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Exact-output swaps are out of scope (MECHANISM.md §2) — always plain AMM.
        if (params.amountSpecified >= 0) {
            emit VenueSkipped(poolId, "exact_output");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (Currency tokenIn, Currency tokenOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Native currency and "no venue configured" both fall straight through to plain AMM.
        if (tokenIn.isAddressZero() || tokenOut.isAddressZero() || address(venueAdapter) == address(0)) {
            emit VenueSkipped(poolId, "no_venue_or_native");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 amountIn = uint256(-params.amountSpecified);

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        HomecomingTypes.Eligibility memory elig = EligibilityLib.evaluate(
            config, sqrtPriceX96, tick, key.tickSpacing, liquidity, lpFee, amountIn, params.zeroForOne
        );

        if (!EligibilityLib.isEligible(elig) || !venueAdapter.isAvailable(tokenIn, tokenOut)) {
            emit VenueSkipped(poolId, "ineligible_or_unavailable");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Attempt the venue leg in an isolated sub-call so a failed/insufficient fill rolls back
        // cleanly (take/transfer/settle all undone) and falls back to plain AMM, instead of
        // reverting the whole swap — see ARCHITECTURE_VALIDATION.md §3 and MECHANISM.md §4.
        try this.attemptVenueRoute(key, tokenIn, tokenOut, amountIn, elig.ammAmountOut, params.zeroForOne) returns (
            BeforeSwapDelta hookDelta, uint256 venueAmountOut, uint256 lpShare, uint256 traderShare
        ) {
            emit VenueRouted(poolId, sender, amountIn, elig.ammAmountOut, venueAmountOut, lpShare, traderShare);
            return (BaseHook.beforeSwap.selector, hookDelta, 0);
        } catch {
            emit VenueSkipped(poolId, "venue_attempt_failed");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
    }

    /// @dev External only so `_beforeSwap` can wrap it in try/catch for atomic rollback of a failed
    /// venue attempt (see MECHANISM.md §4). Restricted to self-calls: `msg.sender` as seen by
    /// PoolManager for the calls made inside is still this hook's own address either way, but an
    /// arbitrary external caller must never be able to trigger PoolManager operations attributed to
    /// this hook outside of an actual swap.
    function attemptVenueRoute(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint256 ammAmountOut,
        bool zeroForOne
    ) external returns (BeforeSwapDelta hookDelta, uint256 venueAmountOut, uint256 lpShare, uint256 traderShare) {
        if (msg.sender != address(this)) revert OnlySelf();

        CurrencySettleLib.take(tokenIn, poolManager, address(this), amountIn);
        IERC20Minimal(Currency.unwrap(tokenIn)).transfer(address(venueAdapter), amountIn);

        uint256 balBefore = tokenOut.balanceOf(address(this));
        (bool ok,) =
            venueAdapter.trySettle(tokenIn, tokenOut, amountIn, ammAmountOut, address(this), abi.encode(ammAmountOut));
        uint256 balAfter = tokenOut.balanceOf(address(this));

        // The adapter's own `ok`/claimed amount is advisory only — the realized balance delta is
        // the sole source of truth (MECHANISM.md §8). Anything less than or equal to the AMM
        // reference is not worth NoOp'ing the AMM for; fall back instead of "succeeding" at parity.
        if (!ok || balAfter <= balBefore || (balAfter - balBefore) <= ammAmountOut) {
            revert VenueSettlementFailed();
        }
        venueAmountOut = balAfter - balBefore;

        uint256 improvement = ImprovementLib.computeImprovement(venueAmountOut, ammAmountOut);
        (lpShare,) = ImprovementLib.splitImprovement(
            improvement, amountIn, config.lpRecaptureBps, config.maxImprovementBpsOfAmountIn
        );
        traderShare = venueAmountOut - lpShare;

        // Pay the trader's share into PoolManager — settles this swap's unspecified-currency delta.
        CurrencySettleLib.settle(tokenOut, poolManager, address(this), traderShare);

        // Donate the LP share directly — already inside this swap's unlock() context.
        if (lpShare > 0) {
            (uint256 amount0, uint256 amount1) = ImprovementLib.toDonationAmounts(lpShare, zeroForOne);
            poolManager.donate(key, amount0, amount1, "");
            CurrencySettleLib.settle(tokenOut, poolManager, address(this), lpShare);
        }

        hookDelta = toBeforeSwapDelta(amountIn.toInt128(), -(traderShare.toInt128()));
    }
}
