// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingTestBase} from "../util/HomecomingTestBase.sol";
import {CowRecaptureReceiver} from "../../src/integrations/cow/CowRecaptureReceiver.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";

/// @notice Integration tests for the real CoW leg. Every payout is either to the pool (donate)
/// or bounded by the named trader's own pre-approved allowance — these tests pin exactly that.
contract CowRecaptureReceiverTest is HomecomingTestBase {
    using StateLibrary for IPoolManager;

    CowRecaptureReceiver receiver;
    HomecomingTypes.Config cfg;

    address trader = makeAddr("cow_trader");
    address attacker = makeAddr("attacker");
    address bystander = makeAddr("bystander");

    function setUp() public {
        _baseSetup();
        cfg = HomecomingTypes.Config({
            minAmountIn: 1, minLiquidity: 0, lpRecaptureBps: 5000, maxImprovementBpsOfAmountIn: 1000
        });
        key = _initDeepPool(IHooks(address(0)));
        receiver = new CowRecaptureReceiver(manager, cfg, address(this));

        // Everyone who might participate gets tokenOut for both directions + a max approval,
        // except `bystander`, who deliberately never approves.
        for (uint256 i = 0; i < 3; i++) {
            address who = [trader, attacker, bystander][i];
            MockERC20(Currency.unwrap(currency0)).mint(who, 100 ether);
            MockERC20(Currency.unwrap(currency1)).mint(who, 100 ether);
        }
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(receiver), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(receiver), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------

    function _ammRef(bool zeroForOne, int256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        BalanceDelta d = swap(key, zeroForOne, amountIn, ZERO_BYTES);
        out = _amountOutFromDelta(d, zeroForOne);
        vm.revertToState(snap);
    }

    function _tokenOut(bool zeroForOne) internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(zeroForOne ? currency1 : currency0));
    }

    struct RecapturedEv {
        bytes32 poolId;
        address trader;
        uint256 amountInClaimed;
        uint256 venueAmountOutClaimed;
        uint256 ammAmountOut;
        uint256 lpShare;
        bool found;
    }

    function _decodeRecaptured(Vm.Log[] memory logs) internal view returns (RecapturedEv memory e) {
        bytes32 sig = keccak256("Recaptured(bytes32,address,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(receiver) && logs[i].topics[0] == sig) {
                e.poolId = logs[i].topics[1];
                e.trader = address(uint160(uint256(logs[i].topics[2])));
                (e.amountInClaimed, e.venueAmountOutClaimed, e.ammAmountOut, e.lpShare) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                e.found = true;
            }
        }
    }

    function _skipReason(Vm.Log[] memory logs) internal view returns (bytes32) {
        bytes32 sig = keccak256("RecaptureSkipped(address,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(receiver) && logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (bytes32));
            }
        }
        return bytes32(0);
    }

    // =======================================================================================
    // happy path
    // =======================================================================================

    function test_recapture_pullsOnlyLpShare_fromTraderAllowance() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammRef(true, amountIn);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        uint256 before = _tokenOut(true).balanceOf(trader);
        vm.recordLogs();
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);
        uint256 pulled = before - _tokenOut(true).balanceOf(trader);

        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());
        assertTrue(e.found);
        uint256 improvement = venueOut - e.ammAmountOut;
        assertEq(pulled, improvement * cfg.lpRecaptureBps / 10_000, "pulls exactly the computed LP share");
        assertEq(pulled, e.lpShare);
        assertLt(pulled, venueOut, "never the trader's whole realized amount");
        assertEq(_tokenOut(true).balanceOf(address(receiver)), 0, "receiver never retains funds");
    }

    function test_recapture_oneForZero() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammRef(false, amountIn);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        uint256 before = _tokenOut(false).balanceOf(trader);
        vm.recordLogs();
        receiver.recapture(key, false, trader, uint256(-amountIn), venueOut);
        uint256 pulled = before - _tokenOut(false).balanceOf(trader);

        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());
        assertTrue(e.found);
        assertGt(pulled, 0);
        assertEq(pulled, e.lpShare);
        assertEq(_tokenOut(false).balanceOf(address(receiver)), 0);
    }

    function test_recapture_creditsInRangeLps_viaFeeGrowth() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammRef(true, amountIn);
        uint256 venueOut = ammOut + (ammOut * 800) / 10_000;

        PoolId id = key.toId();
        uint128 liq = manager.getLiquidity(id);
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);

        vm.recordLogs();
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);
        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertApproxEqAbs(fgAfter - fgBefore, (e.lpShare << 128) / liq, 2, "donation lands in LP fee growth");
    }

    function test_recapture_valueConservation() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammRef(true, amountIn);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        uint256 traderBefore = _tokenOut(true).balanceOf(trader);
        uint256 pmBefore = _tokenOut(true).balanceOf(address(manager));

        vm.recordLogs();
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);
        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());

        assertEq(traderBefore - _tokenOut(true).balanceOf(trader), e.lpShare, "trader debited exactly lpShare");
        assertEq(
            _tokenOut(true).balanceOf(address(manager)) - pmBefore, e.lpShare, "PoolManager credited exactly lpShare"
        );
        assertEq(_tokenOut(true).balanceOf(address(receiver)), 0);
    }

    // =======================================================================================
    // skip reasons
    // =======================================================================================

    function test_skip_zeroAmountInClaim() public {
        vm.recordLogs();
        receiver.recapture(key, true, trader, 0, 1e18);
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("zero_claim"));
    }

    function test_skip_zeroVenueOutClaim() public {
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, 0);
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("zero_claim"));
    }

    function test_skip_outsideCurrentRange() public {
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e30, 2e30); // dwarfs the current cell
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("outside_current_range"));
    }

    function test_skip_noImprovement_venueWorse() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut - (ammOut * 500) / 10_000; // 5% worse
        uint256 before = _tokenOut(true).balanceOf(trader);
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, venueOut);
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("no_improvement"));
        assertEq(_tokenOut(true).balanceOf(trader), before, "nothing pulled");
    }

    function test_skip_noImprovement_lpShareRoundsToZero() public {
        uint256 ammOut = _ammRef(true, -1e18);
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, ammOut + 1); // improvement 1 -> lpShare 0
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("no_improvement"));
    }

    function test_skip_noImprovement_whenLpRecaptureBpsZero() public {
        receiver.setConfig(
            HomecomingTypes.Config({
                minAmountIn: 1, minLiquidity: 0, lpRecaptureBps: 0, maxImprovementBpsOfAmountIn: 1000
            })
        );
        uint256 ammOut = _ammRef(true, -1e18);
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, ammOut + (ammOut * 500) / 10_000);
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("no_improvement"));
    }

    // =======================================================================================
    // allowance / consent bounds — the core safety property
    // =======================================================================================

    function test_pullsNothing_whenAllowanceIsZero() public {
        uint256 ammOut = _ammRef(true, -1e18);
        vm.expectRevert(); // transferFrom with 0 allowance
        receiver.recapture(key, true, bystander, 1e18, ammOut + (ammOut * 500) / 10_000);
    }

    function test_maliciousCaller_namesVictim_boundedByVictimAllowance() public {
        // victim = trader, who set an unlimited approval in setUp. Reduce it to a tight bound.
        vm.prank(trader);
        _tokenOut(true).approve(address(receiver), 1_000);

        uint256 ammOut = _ammRef(true, -1e18);
        uint256 before = _tokenOut(true).balanceOf(trader);

        // attacker drives the call; lpShare would be far above 1_000 -> transferFrom reverts,
        // nothing moves.
        vm.prank(attacker);
        vm.expectRevert();
        receiver.recapture(key, true, trader, 1e18, ammOut + (ammOut * 500) / 10_000);

        assertEq(_tokenOut(true).balanceOf(trader), before, "victim funds untouched beyond their own allowance");
    }

    function test_maliciousCaller_namesSelf_zeroedImprovement_pullsNothing() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 before = _tokenOut(true).balanceOf(attacker);
        vm.prank(attacker);
        vm.recordLogs();
        receiver.recapture(key, true, attacker, 1e18, ammOut); // venue == amm -> improvement 0
        assertEq(_skipReason(vm.getRecordedLogs()), bytes32("no_improvement"));
        assertEq(_tokenOut(true).balanceOf(attacker), before);
    }

    function test_bystander_neverApproved_neverDebited() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 before = _tokenOut(true).balanceOf(bystander);
        vm.prank(attacker);
        try receiver.recapture(key, true, bystander, 1e18, ammOut + (ammOut * 500) / 10_000) {} catch {}
        assertEq(_tokenOut(true).balanceOf(bystander), before);
    }

    function test_twoTraders_callerCannotExceedOtherTraderAllowance() public {
        // trader keeps unlimited; attacker (acting as a second trader) approves only 500.
        vm.prank(attacker);
        _tokenOut(true).approve(address(receiver), 500);

        uint256 ammOut = _ammRef(true, -1e18);
        uint256 atkBefore = _tokenOut(true).balanceOf(attacker);

        vm.prank(trader);
        vm.expectRevert();
        receiver.recapture(key, true, attacker, 1e18, ammOut + (ammOut * 500) / 10_000);

        assertEq(_tokenOut(true).balanceOf(attacker), atkBefore, "second trader bounded by own allowance");
    }

    function test_partialAllowance_revertsWithNoPartialState() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        // enough improvement that lpShare > 1 but allowance is only 1
        vm.prank(trader);
        _tokenOut(true).approve(address(receiver), 1);

        PoolId id = key.toId();
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);

        vm.expectRevert();
        receiver.recapture(key, true, trader, 1e18, venueOut);

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertEq(fgAfter, fgBefore, "no donation on a reverted recapture");
        assertEq(_tokenOut(true).balanceOf(address(receiver)), 0);
    }

    // =======================================================================================
    // cap / config / guards
    // =======================================================================================

    function test_recapture_capBinds_whenImprovementHuge() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut * 3; // improvement ~2x ammOut, way over the cap

        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, venueOut);
        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());

        uint256 cap = e.amountInClaimed * cfg.maxImprovementBpsOfAmountIn / 10_000;
        assertEq(e.lpShare, cap * cfg.lpRecaptureBps / 10_000, "lpShare clamped by amountIn cap");
    }

    function test_setConfig_onlyGovernance() public {
        vm.prank(attacker);
        vm.expectRevert(CowRecaptureReceiver.NotGovernance.selector);
        receiver.setConfig(cfg);
    }

    function test_setConfig_happy() public {
        HomecomingTypes.Config memory c = HomecomingTypes.Config({
            minAmountIn: 2, minLiquidity: 3, lpRecaptureBps: 100, maxImprovementBpsOfAmountIn: 200
        });
        receiver.setConfig(c);
        (uint256 a, uint128 b, uint16 d, uint16 f) = receiver.config();
        assertEq(a, 2);
        assertEq(b, 3);
        assertEq(d, 100);
        assertEq(f, 200);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(CowRecaptureReceiver.NotPoolManager.selector);
        receiver.unlockCallback("");
    }

    function test_unlockCallback_attackerDirectCall_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(CowRecaptureReceiver.NotPoolManager.selector);
        receiver.unlockCallback(abi.encode(key, currency1, uint256(1), uint256(0)));
    }

    // =======================================================================================
    // live-state pricing
    // =======================================================================================

    function test_referencePrice_tracksLivePoolState() public {
        uint256 ammOut1 = _ammRef(true, -1e18);
        uint256 venueOut = ammOut1 * 2;

        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, venueOut);
        uint256 ref1 = _decodeRecaptured(vm.getRecordedLogs()).ammAmountOut;

        // move the pool meaningfully with a large real swap
        swap(key, true, -3e21, ZERO_BYTES);

        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, venueOut);
        uint256 ref2 = _decodeRecaptured(vm.getRecordedLogs()).ammAmountOut;

        assertLt(ref2, ref1, "a worse post-swap price yields a lower AMM reference");
    }

    function test_event_Recaptured_fieldsMatchInputs() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;
        vm.recordLogs();
        receiver.recapture(key, true, trader, 12345e12, venueOut);
        RecapturedEv memory e = _decodeRecaptured(vm.getRecordedLogs());
        assertEq(e.trader, trader);
        assertEq(e.amountInClaimed, 12345e12);
        assertEq(e.venueAmountOutClaimed, venueOut);
        assertEq(e.poolId, PoolId.unwrap(key.toId()));
    }

    // =======================================================================================
    // fuzz
    // =======================================================================================

    function testFuzz_pulledIsFormulaOrZero(uint256 amountInClaimed, uint256 venueDeltaBps) public {
        amountInClaimed = bound(amountInClaimed, 1e12, 5e20);
        venueDeltaBps = bound(venueDeltaBps, 0, 5000);
        uint256 ammOut = _ammRef(true, -int256(amountInClaimed));
        if (ammOut == 0) return;
        uint256 venueOut = ammOut + (ammOut * venueDeltaBps) / 10_000;

        uint256 before = _tokenOut(true).balanceOf(trader);
        vm.recordLogs();
        try receiver.recapture(key, true, trader, amountInClaimed, venueOut) {}
        catch {
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 pulled = before - _tokenOut(true).balanceOf(trader);

        RecapturedEv memory e = _decodeRecaptured(logs);
        if (e.found) {
            assertEq(pulled, e.lpShare);
            assertLt(pulled, venueOut, "never pulls the whole realized amount");
        } else {
            assertEq(pulled, 0, "a skipped recapture pulls nothing");
        }
        assertEq(_tokenOut(true).balanceOf(address(receiver)), 0);
    }

    function testFuzz_neverExceedsAllowance(uint256 allowance, uint256 venueDeltaBps) public {
        allowance = bound(allowance, 0, 5 ether);
        venueDeltaBps = bound(venueDeltaBps, 1, 5000);

        vm.prank(trader);
        _tokenOut(true).approve(address(receiver), allowance);

        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut + (ammOut * venueDeltaBps) / 10_000;
        uint256 before = _tokenOut(true).balanceOf(trader);

        try receiver.recapture(key, true, trader, 1e18, venueOut) {} catch {}

        assertLe(before - _tokenOut(true).balanceOf(trader), allowance, "pull never exceeds the trader's allowance");
    }

    function testFuzz_bystanderNeverDebited(uint256 amountInClaimed, uint256 venueOut) public {
        amountInClaimed = bound(amountInClaimed, 0, 1e30);
        venueOut = bound(venueOut, 0, 1e30);
        uint256 before = _tokenOut(true).balanceOf(bystander);
        try receiver.recapture(key, true, bystander, amountInClaimed, venueOut) {} catch {}
        assertEq(_tokenOut(true).balanceOf(bystander), before);
    }

    function testFuzz_receiverNeverRetainsTokens(uint256 amtIn, uint256 bps, bool zeroForOne) public {
        amtIn = bound(amtIn, 1e14, 4e20);
        bps = bound(bps, 0, 6000);
        uint256 ammOut = _ammRef(zeroForOne, -int256(amtIn));
        if (ammOut == 0) return;
        uint256 venueOut = ammOut + (ammOut * bps) / 10_000;
        try receiver.recapture(key, zeroForOne, trader, amtIn, venueOut) {} catch {}
        assertEq(_tokenOut(zeroForOne).balanceOf(address(receiver)), 0);
        assertEq(MockERC20(Currency.unwrap(zeroForOne ? currency0 : currency1)).balanceOf(address(receiver)), 0);
    }

    function test_recapture_secondCall_afterAllowanceRefreshed() public {
        uint256 ammOut = _ammRef(true, -1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        // first pull uses part of a finite allowance
        vm.prank(trader);
        _tokenOut(true).approve(address(receiver), type(uint256).max);
        receiver.recapture(key, true, trader, 1e18, venueOut);

        // approval auto-decremented (max stays max in solmate) — refresh explicitly and go again
        vm.prank(trader);
        _tokenOut(true).approve(address(receiver), type(uint256).max);
        uint256 before = _tokenOut(true).balanceOf(trader);
        vm.recordLogs();
        receiver.recapture(key, true, trader, 1e18, venueOut);
        assertGt(before - _tokenOut(true).balanceOf(trader), 0, "second recapture still contributes");
    }

    function test_recapture_bothDirections_donateHitsCorrectFeeSide() public {
        PoolId id = key.toId();

        // zeroForOne -> donation in token1 -> feeGrowthGlobal1 moves
        uint256 ammOut = _ammRef(true, -1e18);
        (uint256 fg0a, uint256 fg1a) = manager.getFeeGrowthGlobals(id);
        receiver.recapture(key, true, trader, 1e18, ammOut + (ammOut * 500) / 10_000);
        (uint256 fg0b, uint256 fg1b) = manager.getFeeGrowthGlobals(id);
        assertEq(fg0b, fg0a, "zeroForOne donation must not touch token0 fee growth");
        assertGt(fg1b, fg1a);

        // oneForZero -> donation in token0 -> feeGrowthGlobal0 moves
        uint256 ammOut2 = _ammRef(false, -1e18);
        (fg0a, fg1a) = manager.getFeeGrowthGlobals(id);
        receiver.recapture(key, false, trader, 1e18, ammOut2 + (ammOut2 * 500) / 10_000);
        (fg0b, fg1b) = manager.getFeeGrowthGlobals(id);
        assertGt(fg0b, fg0a);
        assertEq(fg1b, fg1a, "oneForZero donation must not touch token1 fee growth");
    }
}
