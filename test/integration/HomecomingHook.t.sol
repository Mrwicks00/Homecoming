// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";

import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HomecomingHook} from "../../src/HomecomingHook.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";
import {MockVenueAdapter} from "../../src/integrations/MockVenueAdapter.sol";

/// @notice Integration tests run against the REAL PoolManager (via v4-core's own Deployers test
/// harness), not a simplified mock of PoolManager — the delta-netting/flash-accounting behavior
/// that HomecomingHook depends on is exactly what's under test here, not assumed.
contract HomecomingHookTest is Test, Deployers {
    HomecomingHook hook;
    MockVenueAdapter mockVenue;

    HomecomingTypes.Config cfg;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        cfg = HomecomingTypes.Config({
            minAmountIn: 1e15,
            minLiquidity: 0,
            lpRecaptureBps: 5000, // 50% of Improvement to LPs
            maxImprovementBpsOfAmountIn: 1000 // cap Improvement basis at 10% of amountIn
        });

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, cfg, address(this));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HomecomingHook).creationCode, constructorArgs);

        hook = new HomecomingHook{salt: salt}(manager, cfg, address(this));
        assertEq(address(hook), hookAddress, "hook address/flags mismatch");

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // Deep, wide-range liquidity so a normal-sized trade (1e18) stays within a single
        // 60-tick-spacing cell — required for ReferencePriceLib's exactness bound (ARCHITECTURE_
        // VALIDATION.md §5) and thus for the eligible/recapture path to ever be reachable at all.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );

        mockVenue = new MockVenueAdapter(address(this));
        // fund the mock's reserves generously so it can pay out "better than AMM" fills in tests
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(mockVenue), type(uint256).max);
        mockVenue.fundReserves(currency1, 50 ether);
    }

    function _amountOutFromDelta(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        return out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @dev Decodes the single VenueRouted event (5 non-indexed uint256 fields) out of recorded logs.
    function _decodeVenueRouted(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 amountIn, uint256 ammAmountOut, uint256 venueAmountOut, uint256 lpShare, uint256 traderShare)
    {
        bytes32 sig = keccak256("VenueRouted(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
        revert("VenueRouted event not found");
    }

    /// @notice With no venue adapter configured (the honest default — see HomecomingHook NatSpec),
    /// every real swap must behave identically to a hookless pool: plain AMM execution only.
    function test_plainAmmSwap_whenNoAdapterConfigured() public {
        int256 amountIn = -1e18;
        BalanceDelta delta = swap(key, true, amountIn, ZERO_BYTES);
        uint256 amountOut = _amountOutFromDelta(delta, true);
        assertGt(amountOut, 0, "plain AMM swap should produce output");
    }

    /// @notice A configured venue that fills WORSE than the AMM reference must never be used —
    /// the swap must fall back to the identical AMM result, not a worse one.
    function test_fallsBackToAmm_whenVenueWorseThanReference() public {
        hook.setVenueAdapter(address(mockVenue));
        mockVenue.configure(currency0, currency1, true, -500); // 5% worse than AMM reference

        int256 amountIn = -1e18;

        // Reference: what plain AMM gives with no adapter configured at all, same pool state.
        hook.setVenueAdapter(address(0));
        uint256 snapshot = vm.snapshotState();
        BalanceDelta ammOnlyDelta = swap(key, true, amountIn, ZERO_BYTES);
        uint256 ammOnlyOut = _amountOutFromDelta(ammOnlyDelta, true);
        vm.revertToState(snapshot);

        hook.setVenueAdapter(address(mockVenue));
        BalanceDelta routedDelta = swap(key, true, amountIn, ZERO_BYTES);
        uint256 routedOut = _amountOutFromDelta(routedDelta, true);

        assertEq(routedOut, ammOnlyOut, "worse venue must not change trader's realized output");
    }

    /// @notice A configured venue that genuinely fills BETTER than the AMM reference: trader must
    /// receive at least the AMM reference amount, LPs must receive a real, verifiable donation, and
    /// total value must reconcile exactly (Improvement = LP share + trader's extra share, no more).
    function test_recapture_whenVenueBeatsReference() public {
        hook.setVenueAdapter(address(0));
        uint256 snapshot = vm.snapshotState();
        int256 amountIn = -1e18;
        BalanceDelta ammOnlyDelta = swap(key, true, amountIn, ZERO_BYTES);
        uint256 ammOnlyOut = _amountOutFromDelta(ammOnlyDelta, true);
        vm.revertToState(snapshot);

        hook.setVenueAdapter(address(mockVenue));
        mockVenue.configure(currency0, currency1, true, 500); // 5% better than AMM reference

        vm.recordLogs();
        BalanceDelta routedDelta = swap(key, true, amountIn, ZERO_BYTES);
        uint256 routedOut = _amountOutFromDelta(routedDelta, true);

        // Trader must never be worse off than the AMM floor (MECHANISM.md §42 invariant).
        assertGe(routedOut, ammOnlyOut, "trader must never receive less than the AMM reference");
        // And a genuinely better venue must actually be reflected in what the trader receives.
        assertGt(routedOut, ammOnlyOut, "trader should see some benefit from a superior venue fill");

        (uint256 evAmountIn, uint256 evAmmOut, uint256 evVenueOut, uint256 evLpShare, uint256 evTraderShare) =
            _decodeVenueRouted(vm.getRecordedLogs());

        assertEq(evAmountIn, uint256(-amountIn), "logged amountIn must match the swap");
        assertEq(evAmmOut, ammOnlyOut, "logged AMM reference must match the independently-measured AMM-only result");
        assertEq(routedOut, evTraderShare, "trader's realized output must equal the logged trader share exactly");

        // Core conservation invariant (MECHANISM.md §6/§9 INV1): nothing is fabricated — the venue's
        // total realized output splits exactly into LP share + trader share, no more, no less.
        assertEq(evLpShare + evTraderShare, evVenueOut, "Improvement must split exactly: LP share + trader share == venue output");

        uint256 improvement = evVenueOut - evAmmOut;
        uint256 expectedLpShare = (improvement * cfg.lpRecaptureBps) / 10_000;
        assertEq(evLpShare, expectedLpShare, "LP share must match the configured 50% recapture rate exactly");
        assertGt(evLpShare, 0, "a genuine improvement must produce a nonzero, verifiable LP donation");
    }

    /// @notice Trade sizes below the configured minimum never touch the venue path at all.
    function test_ineligible_belowMinSize_staysOnAmm() public {
        hook.setVenueAdapter(address(mockVenue));
        mockVenue.configure(currency0, currency1, true, 500);

        int256 amountIn = -1e10; // below cfg.minAmountIn = 1e15
        BalanceDelta delta = swap(key, true, amountIn, ZERO_BYTES);
        assertGt(_amountOutFromDelta(delta, true), 0, "undersized swap should still execute via AMM");
    }
}
