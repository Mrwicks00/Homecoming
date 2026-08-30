// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingTestBase} from "../util/HomecomingTestBase.sol";
import {CowRecaptureReceiver} from "../../src/integrations/cow/CowRecaptureReceiver.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";
import {CowReceiverHandler} from "./handlers/CowReceiverHandler.sol";

/// @notice System-level invariants for the CoW leg: the receiver never custodies funds, never
/// pulls from a non-participant, and never donates more than it pulled.
contract CowRecaptureReceiverInvariant is StdInvariant, HomecomingTestBase {
    CowRecaptureReceiver receiver;
    CowReceiverHandler handler;

    function setUp() public {
        _baseSetup();
        key = _initDeepPool(IHooks(address(0)));
        receiver = new CowRecaptureReceiver(
            manager,
            HomecomingTypes.Config({
                minAmountIn: 1, minLiquidity: 0, lpRecaptureBps: 5000, maxImprovementBpsOfAmountIn: 1000
            }),
            address(this)
        );
        handler = new CowReceiverHandler(manager, swapRouter, modifyLiquidityNoChecks, receiver, key);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CowReceiverHandler.recapture.selector;
        selectors[1] = CowReceiverHandler.recapture.selector; // weight
        selectors[2] = CowReceiverHandler.setAllowance.selector;
        selectors[3] = CowReceiverHandler.movePool.selector;
        selectors[4] = CowReceiverHandler.addLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_receiverNeverRetainsTokens() public view {
        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(receiver)), 0, "receiver holds currency0");
        assertEq(MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(receiver)), 0, "receiver holds currency1");
    }

    function invariant_bystanderNeverDebited() public view {
        assertEq(
            MockERC20(Currency.unwrap(key.currency0)).balanceOf(handler.bystander()), 1e24, "bystander lost currency0"
        );
        assertEq(
            MockERC20(Currency.unwrap(key.currency1)).balanceOf(handler.bystander()), 1e24, "bystander lost currency1"
        );
    }

    function invariant_donatedNeverExceedsPulled() public view {
        assertLe(handler.totalDonated(), handler.totalPulled(), "donated more than pulled");
    }

    function invariant_pulledEqualsDonated() public view {
        // every unit the receiver pulls is donate()d in the same call — no accumulation anywhere
        assertEq(handler.totalDonated(), handler.totalPulled(), "pull/donate mismatch");
    }

    function invariant_callSummary() public view {
        assertGe(handler.recaptureCalls(), 0);
    }
}
