// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingTestBase} from "../util/HomecomingTestBase.sol";
import {CowRecaptureReceiver} from "../../src/integrations/cow/CowRecaptureReceiver.sol";
import {HooksTrampoline} from "../../src/integrations/cow/vendor/HooksTrampoline.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";

/// @notice The full CoW-leg call path, minus the off-chain solver auction: a (mock) settlement
/// contract drives `HooksTrampoline.execute`, which atomically calls `CowRecaptureReceiver`, which
/// pulls the trader-approved LP share and `donate()`s it. This is the exact production wiring from
/// `DeployCowLeg.s.sol` / `CowRecaptureReceiver.sol` NatSpec — only `GPv2Settlement` is stubbed.
contract CowLegEndToEndTest is HomecomingTestBase {
    using StateLibrary for IPoolManager;

    CowRecaptureReceiver receiver;
    HooksTrampoline trampoline;
    HomecomingTypes.Config cfg;

    address settlement = makeAddr("gpv2_settlement_stub");
    address trader = makeAddr("cow_trader");

    function setUp() public {
        _baseSetup();
        cfg = HomecomingTypes.Config({
            minAmountIn: 1, minLiquidity: 0, lpRecaptureBps: 5000, maxImprovementBpsOfAmountIn: 1000
        });
        key = _initDeepPool(IHooks(address(0)));
        receiver = new CowRecaptureReceiver(manager, cfg, address(this));
        trampoline = new HooksTrampoline(settlement);

        MockERC20(Currency.unwrap(currency1)).mint(trader, 100 ether);
        vm.prank(trader);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);
    }

    function _ammRef(int256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        BalanceDelta d = swap(key, true, amountIn, ZERO_BYTES);
        out = uint256(uint128(d.amount1()));
        vm.revertToState(snap);
    }

    function _postHook(address t, uint256 amtIn, uint256 venueOut)
        internal
        view
        returns (HooksTrampoline.Hook[] memory h)
    {
        h = new HooksTrampoline.Hook[](1);
        h[0] = HooksTrampoline.Hook({
            target: address(receiver),
            callData: abi.encodeCall(CowRecaptureReceiver.recapture, (key, true, t, amtIn, venueOut)),
            gasLimit: 3_000_000
        });
    }

    function test_e2e_settlementDrivenRecapture_donatesLpShare() public {
        uint256 ammOut = _ammRef(-1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        PoolId id = key.toId();
        uint128 liq = manager.getLiquidity(id);
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);
        uint256 traderBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.recordLogs();
        vm.prank(settlement);
        trampoline.execute(_postHook(trader, 1e18, venueOut));

        // decode the Recaptured event to learn lpShare
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 lpShare;
        bytes32 sig = keccak256("Recaptured(bytes32,address,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(receiver) && logs[i].topics[0] == sig) {
                (,,, lpShare) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        assertGt(lpShare, 0);
        assertEq(
            traderBefore - MockERC20(Currency.unwrap(currency1)).balanceOf(trader),
            lpShare,
            "trader debited exactly lpShare"
        );

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertApproxEqAbs(fgAfter - fgBefore, (lpShare << 128) / liq, 2, "donation reached in-range LPs");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(receiver)), 0, "receiver custodies nothing");
    }

    function test_e2e_recaptureRevert_doesNotRevertTheSettlement() public {
        // trader revokes approval -> the receiver's transferFrom will revert inside the trampoline,
        // which by design swallows it so the batch (and every other order) still settles.
        vm.prank(trader);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), 0);

        uint256 ammOut = _ammRef(-1e18);
        PoolId id = key.toId();
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);

        vm.prank(settlement);
        trampoline.execute(_postHook(trader, 1e18, ammOut + (ammOut * 500) / 10_000)); // must NOT revert

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertEq(fgAfter, fgBefore, "no donation happened");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(receiver)), 0);
    }

    function test_e2e_worseVenueClaim_settlesWithNoRecapture() public {
        uint256 ammOut = _ammRef(-1e18);
        PoolId id = key.toId();
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);

        vm.prank(settlement);
        trampoline.execute(_postHook(trader, 1e18, ammOut - 1)); // venue "worse" than AMM

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertEq(fgAfter, fgBefore);
    }

    function test_e2e_onlySettlementCanDriveTheTrampoline() public {
        uint256 ammOut = _ammRef(-1e18);
        vm.prank(makeAddr("not_settlement"));
        vm.expectRevert(HooksTrampoline.NotASettlement.selector);
        trampoline.execute(_postHook(trader, 1e18, ammOut + (ammOut * 500) / 10_000));
    }

    function test_e2e_directReceiverCall_stillWorks_permissionlessByDesign() public {
        // The receiver is intentionally callable without the trampoline (it is permissionless);
        // the trampoline only bounds gas and blast radius. Prove a direct call behaves identically.
        uint256 ammOut = _ammRef(-1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;
        uint256 before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);
        receiver.recapture(key, true, trader, 1e18, venueOut);
        assertGt(before - MockERC20(Currency.unwrap(currency1)).balanceOf(trader), 0);
    }

    function test_e2e_twoPostHooksInOneBatch_independent() public {
        address trader2 = makeAddr("cow_trader_2");
        MockERC20(Currency.unwrap(currency1)).mint(trader2, 100 ether);
        vm.prank(trader2);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);

        uint256 ammOut = _ammRef(-1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        HooksTrampoline.Hook[] memory hooks = new HooksTrampoline.Hook[](2);
        hooks[0] = HooksTrampoline.Hook(
            address(receiver),
            abi.encodeCall(CowRecaptureReceiver.recapture, (key, true, trader, 1e18, venueOut)),
            3_000_000
        );
        hooks[1] = HooksTrampoline.Hook(
            address(receiver),
            abi.encodeCall(CowRecaptureReceiver.recapture, (key, true, trader2, 1e18, venueOut)),
            3_000_000
        );

        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);
        uint256 t2Before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader2);

        vm.prank(settlement);
        trampoline.execute(hooks);

        assertGt(t1Before - MockERC20(Currency.unwrap(currency1)).balanceOf(trader), 0, "trader 1 contributed");
        assertGt(t2Before - MockERC20(Currency.unwrap(currency1)).balanceOf(trader2), 0, "trader 2 contributed");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(receiver)), 0);
    }

    function test_e2e_tinyGasLimit_recaptureSkipped_settlementUnharmed() public {
        uint256 ammOut = _ammRef(-1e18);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        HooksTrampoline.Hook[] memory hooks = new HooksTrampoline.Hook[](1);
        hooks[0] = HooksTrampoline.Hook({
            target: address(receiver),
            callData: abi.encodeCall(CowRecaptureReceiver.recapture, (key, true, trader, uint256(1e18), venueOut)),
            gasLimit: 30_000 // far too little to run recapture
        });

        PoolId id = key.toId();
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);
        uint256 before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.prank(settlement);
        trampoline.execute(hooks); // must not revert

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertEq(fgAfter, fgBefore, "under-gassed recapture simply does nothing");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(trader), before);
    }

    function test_e2e_ineligibleClaim_outsideRange_settlesCleanly() public {
        PoolId id = key.toId();
        (, uint256 fgBefore) = manager.getFeeGrowthGlobals(id);

        vm.prank(settlement);
        trampoline.execute(_postHook(trader, 1e30, 2e30)); // claim dwarfs the cell -> receiver skips

        (, uint256 fgAfter) = manager.getFeeGrowthGlobals(id);
        assertEq(fgAfter, fgBefore);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(receiver)), 0);
    }
}
