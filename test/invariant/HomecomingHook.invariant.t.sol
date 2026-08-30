// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingTestBase} from "../util/HomecomingTestBase.sol";
import {HomecomingHook} from "../../src/HomecomingHook.sol";
import {HomecomingHookHandler} from "./handlers/HomecomingHookHandler.sol";

/// @notice System-level invariants for Homecoming Core, driven by a stateful handler against the
/// real PoolManager. Enforces MECHANISM.md §9 INV1/INV3/INV4/INV5 as executable properties.
contract HomecomingHookInvariant is StdInvariant, HomecomingTestBase {
    HomecomingHook hook;
    HomecomingHookHandler handler;
    address gov = makeAddr("gov");

    function setUp() public {
        _baseSetup();
        hook = _mineAndDeployHook(DEFAULT_CFG, gov);
        key = _initDeepPool(IHooks(address(hook)));

        handler = new HomecomingHookHandler(manager, swapRouter, modifyLiquidityNoChecks, hook, gov, key);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = HomecomingHookHandler.swapExactIn.selector;
        selectors[1] = HomecomingHookHandler.swapNoAdapter.selector;
        selectors[2] = HomecomingHookHandler.addLiquidity.selector;
        selectors[3] = HomecomingHookHandler.removeLiquidity.selector;
        selectors[4] = HomecomingHookHandler.retuneConfig.selector;
        selectors[5] = HomecomingHookHandler.swapExactIn.selector; // weight swaps more heavily
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The hook is a pass-through: it must never sit on trader or LP funds between calls.
    function invariant_hookNeverRetainsTokens() public view {
        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(hook)), 0, "hook holds currency0");
        assertEq(MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(hook)), 0, "hook holds currency1");
    }

    /// @dev INV4: a failing/worse/absent venue leg degrades to plain AMM — never a stuck trade.
    function invariant_swapsNeverRevert() public view {
        assertFalse(handler.sawSwapRevert(), "a bounded swap reverted - AMM fallback failed");
    }

    /// @dev INV1/INV5 at system scale: donations never exceed realized Improvement in aggregate.
    function invariant_lpDonationsNeverExceedRealizedImprovement() public view {
        assertLe(handler.totalLpDonated(), handler.totalImprovement(), "donated more than was actually improved");
    }

    /// @dev config the hook actually holds is always within bounds (regression guard on setConfig).
    function invariant_configIsAlwaysSane() public view {
        (,, uint16 lpBps, uint16 maxBps) = hook.config();
        assertLe(lpBps, 10_000);
        assertLe(maxBps, 10_000);
    }

    /// @dev No VenueRouted was ever counted without a strictly positive Improvement behind it.
    function invariant_routedImpliesImprovement() public view {
        if (handler.routedSwaps() > 0) assertGt(handler.totalImprovement(), 0, "routed with zero total improvement");
    }

    function invariant_callSummary() public view {
        assertGe(handler.swaps(), 0);
    }
}
