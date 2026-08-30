// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingTestBase} from "../util/HomecomingTestBase.sol";
import {HomecomingHook} from "../../src/HomecomingHook.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";
import {ImprovementLib} from "../../src/libraries/ImprovementLib.sol";
import {MockVenueAdapter} from "../../src/integrations/MockVenueAdapter.sol";
import {MaliciousVenueAdapter} from "../util/MaliciousVenueAdapter.sol";

/// @notice Integration tests against the REAL PoolManager (v4-core `Deployers`) — the
/// flash-accounting / delta-netting behaviour HomecomingHook depends on is what is under test,
/// not assumed. Covers routing, fallback, recapture, caps, governance, events and value
/// conservation.
contract HomecomingHookTest is HomecomingTestBase {
    using StateLibrary for IPoolManager;

    HomecomingHook hook;
    MockVenueAdapter mockVenue;
    MaliciousVenueAdapter evilVenue;

    function setUp() public {
        _baseSetup();
        hook = _mineAndDeployHook(DEFAULT_CFG, address(this));
        key = _initDeepPool(IHooks(address(hook)));

        mockVenue = new MockVenueAdapter(address(this));
        evilVenue = new MaliciousVenueAdapter();
        evilVenue.setHook(address(hook));

        // Fund both mock venues with both tokens so either swap direction can be paid.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 500 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 500 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(mockVenue), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(mockVenue), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(evilVenue), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(evilVenue), type(uint256).max);
        mockVenue.fundReserves(currency0, 100 ether);
        mockVenue.fundReserves(currency1, 100 ether);
        evilVenue.fundReserves(currency0, 100 ether);
        evilVenue.fundReserves(currency1, 100 ether);
    }

    // ---------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------

    function _enableMock(bool zeroForOne, int256 bps) internal {
        hook.setVenueAdapter(address(mockVenue));
        (Currency tIn, Currency tOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        mockVenue.configure(tIn, tOut, true, bps);
    }

    function _enableEvil(bool zeroForOne, MaliciousVenueAdapter.Mode m) internal {
        hook.setVenueAdapter(address(evilVenue));
        evilVenue.setMode(m);
        (Currency tIn, Currency tOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        evilVenue.enablePair(tIn, tOut, true);
    }

    function _hookHoldsNothing() internal view {
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "hook retained currency0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "hook retained currency1");
    }

    // =======================================================================================
    // baseline: no adapter / honest defaults
    // =======================================================================================

    function test_plainAmmSwap_whenNoAdapterConfigured() public {
        BalanceDelta delta = swap(key, true, -1e18, ZERO_BYTES);
        assertGt(_amountOutFromDelta(delta, true), 0);
        _hookHoldsNothing();
    }

    function test_noAdapter_emitsSkip_noVenueOrNative() public {
        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "no_venue_or_native"), 1);
    }

    function test_ineligible_belowMinSize_staysOnAmm() public {
        _enableMock(true, 500);
        vm.recordLogs();
        BalanceDelta delta = swap(key, true, -1e10, ZERO_BYTES); // below cfg.minAmountIn = 1e15
        assertGt(_amountOutFromDelta(delta, true), 0);
        assertFalse(_hasVenueRouted(vm.getRecordedLogs(), address(hook)));
    }

    function test_exactOutput_takesAmmPath_emitsExactOutputSkip() public {
        _enableMock(true, 500);
        vm.recordLogs();
        BalanceDelta delta = swap(key, true, 1e17, ZERO_BYTES); // positive = exact output
        assertEq(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "exact_output"), 1);
        // exact-output: trader received exactly the requested output
        assertEq(uint256(uint128(delta.amount1())), 1e17);
        _hookHoldsNothing();
    }

    function test_nativeCurrencyPool_skipsVenueLogic() public {
        (PoolKey memory nkey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        hook.setVenueAdapter(address(mockVenue));

        vm.recordLogs();
        swap(nkey, true, -1e15, ZERO_BYTES);
        assertEq(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "no_venue_or_native"), 1);
    }

    function test_adapterUnavailable_forPair_skips() public {
        hook.setVenueAdapter(address(mockVenue)); // pair never configured -> isAvailable == false
        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "ineligible_or_unavailable"), 1);
    }

    function test_tickCrossingTrade_ineligible_takesAmm() public {
        _enableMock(true, 500);
        vm.recordLogs();
        BalanceDelta delta = swap(key, true, -8e21, ZERO_BYTES); // large enough to leave the 60-tick cell
        assertGt(_amountOutFromDelta(delta, true), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_hasVenueRouted(logs, address(hook)));
        assertEq(_countVenueSkipped(logs, address(hook), "ineligible_or_unavailable"), 1);
    }

    // =======================================================================================
    // fallback: worse / failing venue must never change the trader's result
    // =======================================================================================

    function test_fallsBackToAmm_whenVenueWorseThanReference() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableMock(true, -500); // 5% worse
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly, "worse venue must not change trader output");
        _hookHoldsNothing();
    }

    function test_fallsBack_whenVenueFillsExactlyAtReference() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableMock(true, 0); // parity — not strictly better
        vm.recordLogs();
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly, "parity fill falls back");
        assertFalse(_hasVenueRouted(vm.getRecordedLogs(), address(hook)));
    }

    function test_fallsBack_whenAdapterReverts_byteIdentical() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.RevertInSettle);
        vm.recordLogs();
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
        assertEq(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "venue_attempt_failed"), 1);
        _hookHoldsNothing();
    }

    function test_fallsBack_whenAdapterReturnsFalse() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.ReturnFalse);
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
        _hookHoldsNothing();
    }

    function test_fallsBack_whenAdapterPaysNothing() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.PayNothing);
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
        _hookHoldsNothing();
    }

    function test_fallsBack_whenAdapterUnderpaysByOneWei() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.Underpay);
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
    }

    function test_inflatedClaimIgnored_realizedUsed_fallsBack() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.InflatedClaim); // pays parity, claims uint128 max
        vm.recordLogs();
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly, "claim is advisory; realized parity -> fallback");
        assertFalse(_hasVenueRouted(vm.getRecordedLogs(), address(hook)));
    }

    function test_reentrancy_adapterCallsAttemptRoute_fallsBack() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.ReenterAttemptRoute);
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
        _hookHoldsNothing();
    }

    function test_reentrancy_adapterCallsGovernance_fallsBack() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableEvil(true, MaliciousVenueAdapter.Mode.ReenterGovernance);
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(routed, true), ammOnly);
        // governance untouched
        assertEq(address(hook.venueAdapter()), address(evilVenue));
    }

    // =======================================================================================
    // recapture: genuinely better venue
    // =======================================================================================

    function test_recapture_whenVenueBeatsReference_zeroForOne() public {
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        _enableMock(true, 500); // +5%

        vm.recordLogs();
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        uint256 routedOut = _amountOutFromDelta(routed, true);

        assertGe(routedOut, ammOnly, "trader never below the AMM floor");
        assertGt(routedOut, ammOnly, "a superior venue benefits the trader");

        (uint256 evIn, uint256 evAmm, uint256 evVenue, uint256 evLp, uint256 evTrader) =
            _decodeVenueRouted(vm.getRecordedLogs(), address(hook));
        assertEq(evIn, 1e18);
        assertEq(evAmm, ammOnly, "logged reference == independent AMM-only measurement");
        assertEq(routedOut, evTrader, "trader realized output == logged trader share");
        assertEq(evLp + evTrader, evVenue, "venue output splits exactly, nothing fabricated");

        uint256 improvement = evVenue - evAmm;
        assertEq(evLp, improvement * DEFAULT_CFG.lpRecaptureBps / 10_000, "50% recapture rate");
        assertGt(evLp, 0);
        _hookHoldsNothing();
    }

    function test_recapture_whenVenueBeatsReference_oneForZero() public {
        uint256 ammOnly = _ammReferenceOut(key, false, -1e18);
        _enableMock(false, 500);

        vm.recordLogs();
        BalanceDelta routed = swap(key, false, -1e18, ZERO_BYTES);
        uint256 routedOut = _amountOutFromDelta(routed, false);

        assertGt(routedOut, ammOnly);
        (,, uint256 evVenue, uint256 evLp, uint256 evTrader) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));
        assertEq(evLp + evTrader, evVenue);
        assertGt(evLp, 0);
        _hookHoldsNothing();
    }

    function test_recapture_capBinds_whenImprovementHuge() public {
        _enableMock(true, 5000); // venue fills 50% better -> improvement dwarfs the cap

        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        (uint256 evIn,,, uint256 evLp,) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));

        uint256 cap = evIn * DEFAULT_CFG.maxImprovementBpsOfAmountIn / 10_000;
        uint256 expectedLp = cap * DEFAULT_CFG.lpRecaptureBps / 10_000;
        assertEq(evLp, expectedLp, "lpShare clamped by maxImprovementBpsOfAmountIn cap");
        _hookHoldsNothing();
    }

    function test_recapture_lpRecaptureBpsZero_noDonation() public {
        hook.setConfig(
            HomecomingTypes.Config({
                minAmountIn: 1e15, minLiquidity: 0, lpRecaptureBps: 0, maxImprovementBpsOfAmountIn: 1000
            })
        );
        _enableMock(true, 500);

        vm.recordLogs();
        BalanceDelta routed = swap(key, true, -1e18, ZERO_BYTES);
        (,, uint256 evVenue, uint256 evLp, uint256 evTrader) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));
        assertEq(evLp, 0);
        assertEq(evTrader, evVenue, "with no LP cut the trader keeps the whole venue fill");
        assertEq(_amountOutFromDelta(routed, true), evVenue);
        _hookHoldsNothing();
    }

    function test_recapture_lpRecaptureBpsFull_allCappedBasisToLps() public {
        hook.setConfig(
            HomecomingTypes.Config({
                minAmountIn: 1e15, minLiquidity: 0, lpRecaptureBps: 10_000, maxImprovementBpsOfAmountIn: 1000
            })
        );
        _enableMock(true, 5000);

        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        (uint256 evIn,,, uint256 evLp,) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));
        uint256 cap = evIn * 1000 / 10_000;
        assertEq(evLp, cap, "full recapture rate -> lpShare == capped basis");
    }

    function test_recapture_realInRangeLpsCredited_viaFeeGrowth() public {
        _enableMock(true, 500);

        PoolId id = key.toId();
        uint128 liq = manager.getLiquidity(id);
        (, uint256 fg1Before) = manager.getFeeGrowthGlobals(id);

        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        (,,, uint256 evLp,) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));

        (, uint256 fg1After) = manager.getFeeGrowthGlobals(id);
        // donate() increments feeGrowthGlobal1 by lpShare * 2**128 / liquidity (token1 side for a
        // zeroForOne trade). The AMM swap itself was substituted, so this is the only contribution.
        uint256 expectedDelta = (evLp << 128) / liq;
        assertApproxEqAbs(fg1After - fg1Before, expectedDelta, 2, "donation must land in in-range LP fee growth");
        assertGt(evLp, 0);
    }

    function test_sequentialRecaptureSwaps_eachDonates() public {
        _enableMock(true, 500);
        PoolId id = key.toId();
        (, uint256 fgPrev) = manager.getFeeGrowthGlobals(id);
        for (uint256 i = 0; i < 3; i++) {
            swap(key, true, -5e17, ZERO_BYTES);
            (, uint256 fgNow) = manager.getFeeGrowthGlobals(id);
            assertGt(fgNow, fgPrev, "each recapture swap raises fee growth");
            fgPrev = fgNow;
            _hookHoldsNothing();
        }
    }

    function test_configChangeMidStream_appliesNewRate() public {
        _enableMock(true, 500);

        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        (,,, uint256 lpA,) = _decodeVenueRouted(vm.getRecordedLogs(), address(hook));

        hook.setConfig(
            HomecomingTypes.Config({
                minAmountIn: 1e15, minLiquidity: 0, lpRecaptureBps: 2500, maxImprovementBpsOfAmountIn: 1000
            })
        );

        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        (uint256 evInB, uint256 evAmmB, uint256 evVenueB, uint256 lpB,) =
            _decodeVenueRouted(vm.getRecordedLogs(), address(hook));

        assertLt(lpB, lpA, "halved recapture rate -> smaller LP share");

        // Recompute the split from the *logged* reference/venue numbers (the exact inputs the
        // hook used), against the new 2500bps rate — no re-measurement of a shifted pool.
        (uint256 expectedLpB,) = ImprovementLib.splitImprovement(evVenueB - evAmmB, evInB, 2500, 1000);
        assertEq(lpB, expectedLpB, "second swap uses the updated recapture rate");
    }

    // =======================================================================================
    // governance
    // =======================================================================================

    function test_setVenueAdapter_onlyGovernance() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(HomecomingHook.NotGovernance.selector);
        hook.setVenueAdapter(address(mockVenue));
    }

    function test_setConfig_onlyGovernance() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(HomecomingHook.NotGovernance.selector);
        hook.setConfig(DEFAULT_CFG);
    }

    function test_setVenueAdapter_happy_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit HomecomingHook.VenueAdapterUpdated(address(mockVenue));
        hook.setVenueAdapter(address(mockVenue));
        assertEq(address(hook.venueAdapter()), address(mockVenue));
    }

    function test_setConfig_happy_updatesAndEmits() public {
        HomecomingTypes.Config memory c = HomecomingTypes.Config({
            minAmountIn: 7, minLiquidity: 9, lpRecaptureBps: 111, maxImprovementBpsOfAmountIn: 222
        });
        vm.expectEmit(false, false, false, true, address(hook));
        emit HomecomingHook.ConfigUpdated(7, 9, 111, 222);
        hook.setConfig(c);
        (uint256 minIn, uint128 minLiq, uint16 lpBps, uint16 maxBps) = hook.config();
        assertEq(minIn, 7);
        assertEq(minLiq, 9);
        assertEq(lpBps, 111);
        assertEq(maxBps, 222);
    }

    // =======================================================================================
    // guards / structure
    // =======================================================================================

    function test_attemptVenueRoute_directCall_revertsOnlySelf() public {
        vm.expectRevert(HomecomingHook.OnlySelf.selector);
        hook.attemptVenueRoute(key, currency0, currency1, 1e18, 1e17, true);
    }

    function test_getHookPermissions_onlyBeforeSwapAndReturnDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwap);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
    }

    function test_hookAddress_encodesExactlyTheRequiredFlags() public view {
        uint160 bits = uint160(address(hook)) & uint160(0x3FFF); // low 14 bits
        uint160 expected = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(bits, expected, "address must encode exactly {beforeSwap, beforeSwapReturnDelta}");
    }

    function test_garbageHookData_isIgnored() public {
        _enableMock(true, 500);
        uint256 snap = vm.snapshotState();
        uint256 withZero = _amountOutFromDelta(swap(key, true, -1e18, ZERO_BYTES), true);
        vm.revertToState(snap);
        uint256 withGarbage = _amountOutFromDelta(swap(key, true, -1e18, hex"deadbeefcafe"), true);
        assertEq(withZero, withGarbage, "hookData is not read by the hook");
    }

    // =======================================================================================
    // fuzz
    // =======================================================================================

    function testFuzz_traderNeverBelowAmmFloor(int256 bps, uint256 amountIn, bool zeroForOne) public {
        bps = bound(bps, -2000, 4000);
        amountIn = bound(amountIn, 1e15, 2e21);
        uint256 ammOnly = _ammReferenceOut(key, zeroForOne, -int256(amountIn));

        _enableMock(zeroForOne, bps);
        BalanceDelta routed = swap(key, zeroForOne, -int256(amountIn), ZERO_BYTES);
        uint256 routedOut = _amountOutFromDelta(routed, zeroForOne);

        assertGe(routedOut + 2, ammOnly, "trader is never materially worse off than plain AMM");
        _hookHoldsNothing();
    }

    function testFuzz_recaptureSplitMatchesFormula(uint256 bps, uint256 amountIn) public {
        bps = bound(bps, 20, 3000); // strictly-better venue
        amountIn = bound(amountIn, 1e16, 1e21);
        _enableMock(true, int256(bps));

        vm.recordLogs();
        swap(key, true, -int256(amountIn), ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!_hasVenueRouted(logs, address(hook))) return; // rounding edge -> fell back, fine

        (uint256 evIn, uint256 evAmm, uint256 evVenue, uint256 evLp, uint256 evTrader) =
            _decodeVenueRouted(logs, address(hook));

        uint256 improvement = evVenue - evAmm;
        (uint256 expectedLp,) = ImprovementLib.splitImprovement(
            improvement, evIn, DEFAULT_CFG.lpRecaptureBps, DEFAULT_CFG.maxImprovementBpsOfAmountIn
        );
        assertEq(evLp, expectedLp, "on-chain split == pure formula");
        assertEq(evLp + evTrader, evVenue, "conservation");
        _hookHoldsNothing();
    }

    function testFuzz_hookNeverRetainsTokens_anyPathAnyDirection(uint256 mode, uint256 amountSeed, bool zeroForOne)
        public
    {
        uint256 amountIn = bound(amountSeed, 1e15, 3e21);
        uint256 m = mode % 4;
        if (m == 0) {
            // no adapter
        } else if (m == 1) {
            _enableMock(zeroForOne, -300); // worse -> fallback
        } else if (m == 2) {
            _enableMock(zeroForOne, 400); // better -> recapture
        } else {
            _enableEvil(zeroForOne, MaliciousVenueAdapter.Mode.RevertInSettle); // revert -> fallback
        }
        swap(key, zeroForOne, -int256(amountIn), ZERO_BYTES);
        _hookHoldsNothing();
    }

    function test_adapterSwitchedOffMidStream_returnsToPlainAmm() public {
        _enableMock(true, 500);
        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        assertTrue(_hasVenueRouted(vm.getRecordedLogs(), address(hook)));

        hook.setVenueAdapter(address(0));
        uint256 ammOnly = _ammReferenceOut(key, true, -1e18);
        vm.recordLogs();
        BalanceDelta d = swap(key, true, -1e18, ZERO_BYTES);
        assertEq(_amountOutFromDelta(d, true), ammOnly);
        assertFalse(_hasVenueRouted(vm.getRecordedLogs(), address(hook)));
    }

    function test_venueSkipped_reason_isNonEmpty_forEverySkipPath() public {
        // no adapter
        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        assertGt(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "no_venue_or_native"), 0);

        // exact output
        vm.recordLogs();
        swap(key, true, 1e16, ZERO_BYTES);
        assertGt(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "exact_output"), 0);

        // ineligible (adapter set, pair not configured)
        hook.setVenueAdapter(address(mockVenue));
        vm.recordLogs();
        swap(key, true, -1e18, ZERO_BYTES);
        assertGt(_countVenueSkipped(vm.getRecordedLogs(), address(hook), "ineligible_or_unavailable"), 0);
    }
}
