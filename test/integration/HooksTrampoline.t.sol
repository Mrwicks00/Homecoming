// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HooksTrampoline} from "../../src/integrations/cow/vendor/HooksTrampoline.sol";

contract HookTarget {
    uint256 public calls;
    uint256 public lastGas;
    bool public shouldRevert;

    function ping() external {
        calls++;
        lastGas = gasleft();
        if (shouldRevert) revert("target boom");
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }
}

/// @notice Coverage for the vendored `HooksTrampoline` — the CoW-side isolation boundary the
/// recapture receiver is invoked through. Vendored verbatim, but this project ships it, so it
/// gets tested here rather than trusted blind.
contract HooksTrampolineTest is Test {
    HooksTrampoline trampoline;
    HookTarget target;
    address settlement = makeAddr("gpv2_settlement");

    function setUp() public {
        trampoline = new HooksTrampoline(settlement);
        target = new HookTarget();
    }

    function _one(address t, bytes memory cd, uint256 gas) internal pure returns (HooksTrampoline.Hook[] memory hooks) {
        hooks = new HooksTrampoline.Hook[](1);
        hooks[0] = HooksTrampoline.Hook({target: t, callData: cd, gasLimit: gas});
    }

    function test_settlementAddress_isImmutableConstructorArg() public view {
        assertEq(trampoline.settlement(), settlement);
    }

    function test_execute_revertsWhenNotCalledBySettlement() public {
        vm.expectRevert(HooksTrampoline.NotASettlement.selector);
        trampoline.execute(_one(address(target), abi.encodeCall(HookTarget.ping, ()), 100_000));
    }

    function test_execute_revertsForArbitraryCaller() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(HooksTrampoline.NotASettlement.selector);
        trampoline.execute(_one(address(target), abi.encodeCall(HookTarget.ping, ()), 100_000));
    }

    function test_execute_invokesHookTarget() public {
        vm.prank(settlement);
        trampoline.execute(_one(address(target), abi.encodeCall(HookTarget.ping, ()), 200_000));
        assertEq(target.calls(), 1);
    }

    function test_execute_multipleHooks_allInvoked() public {
        HookTarget t2 = new HookTarget();
        HooksTrampoline.Hook[] memory hooks = new HooksTrampoline.Hook[](2);
        hooks[0] = HooksTrampoline.Hook(address(target), abi.encodeCall(HookTarget.ping, ()), 200_000);
        hooks[1] = HooksTrampoline.Hook(address(t2), abi.encodeCall(HookTarget.ping, ()), 200_000);
        vm.prank(settlement);
        trampoline.execute(hooks);
        assertEq(target.calls(), 1);
        assertEq(t2.calls(), 1);
    }

    function test_execute_revertingHookDoesNotRevertTheBatch() public {
        target.setRevert(true);
        HookTarget t2 = new HookTarget();
        HooksTrampoline.Hook[] memory hooks = new HooksTrampoline.Hook[](2);
        hooks[0] = HooksTrampoline.Hook(address(target), abi.encodeCall(HookTarget.ping, ()), 200_000);
        hooks[1] = HooksTrampoline.Hook(address(t2), abi.encodeCall(HookTarget.ping, ()), 200_000);

        vm.prank(settlement);
        trampoline.execute(hooks); // must not revert

        assertEq(t2.calls(), 1, "a reverting hook must not block later hooks / the settlement");
    }

    function test_execute_forwardsAtMostTheHookGasLimit() public {
        vm.prank(settlement);
        trampoline.execute(_one(address(target), abi.encodeCall(HookTarget.ping, ()), 80_000));
        assertLt(target.lastGas(), 80_000, "hook ran within its declared gas budget");
    }

    function test_execute_emptyHookArray_isNoop() public {
        vm.prank(settlement);
        trampoline.execute(new HooksTrampoline.Hook[](0));
        assertEq(target.calls(), 0);
    }

    function test_execute_wastesGasWhenInsufficientForwarded() public {
        // Provide far less gas than the hook demands -> forwardedGas < gasLimit -> revertByWastingGas
        HooksTrampoline.Hook[] memory hooks = _one(address(target), abi.encodeCall(HookTarget.ping, ()), 30_000_000);
        vm.prank(settlement);
        (bool ok,) = address(trampoline).call{gas: 200_000}(abi.encodeCall(HooksTrampoline.execute, (hooks)));
        assertFalse(ok, "insufficient forwarded gas must fail loudly, not silently under-run the hook");
        assertEq(target.calls(), 0);
    }
}
