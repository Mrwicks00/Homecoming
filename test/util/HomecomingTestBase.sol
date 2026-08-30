// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {HomecomingHook} from "../../src/HomecomingHook.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";
import {MockVenueAdapter} from "../../src/integrations/MockVenueAdapter.sol";

/// @notice Shared setup + assertions for every Homecoming test that needs a real PoolManager.
/// Pulls the pool/liquidity/hook-mining boilerplate and the delta/event decoders out of the
/// individual suites so they are defined once (they were previously copy-pasted).
abstract contract HomecomingTestBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    /// @dev The wide range used so a normal-sized (~1e18) trade provably stays inside one
    /// 60-tick-spacing cell — required for ReferencePriceLib's exactness bound to hold, and
    /// therefore for the eligible/recapture path to be reachable at all.
    int24 internal constant WIDE_TICK_LOWER = -887220;
    int24 internal constant WIDE_TICK_UPPER = 887220;
    uint128 internal constant DEEP_LIQUIDITY = 1e24;
    uint24 internal constant FEE_3000 = 3000;
    int24 internal constant SPACING_60 = 60;

    HomecomingTypes.Config internal DEFAULT_CFG = HomecomingTypes.Config({
        minAmountIn: 1e15,
        minLiquidity: 0,
        lpRecaptureBps: 5000, // 50% of Improvement to LPs
        maxImprovementBpsOfAmountIn: 1000 // Improvement basis capped at 10% of amountIn
    });

    function _baseSetup() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    // ---------------------------------------------------------------------------------------
    // Deployment helpers
    // ---------------------------------------------------------------------------------------

    function _mineAndDeployHook(HomecomingTypes.Config memory cfg, address governance)
        internal
        returns (HomecomingHook hook)
    {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager, cfg, governance);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HomecomingHook).creationCode, args);
        hook = new HomecomingHook{salt: salt}(manager, cfg, governance);
        require(address(hook) == predicted, "HomecomingTestBase: hook address/flags mismatch");
    }

    /// @notice Initialize a 0.3% pool at 1:1 and seed it with a wide, deep position so the
    /// reference-price cell bound is satisfied for realistic trade sizes.
    function _initDeepPool(IHooks hooks) internal returns (PoolKey memory k) {
        (k,) = initPoolAndAddLiquidity(currency0, currency1, hooks, FEE_3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: WIDE_TICK_LOWER,
                tickUpper: WIDE_TICK_UPPER,
                liquidityDelta: int256(uint256(DEEP_LIQUIDITY)),
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _deployAndFundMockVenue(Currency payoutToken, uint256 reserves) internal returns (MockVenueAdapter venue) {
        venue = new MockVenueAdapter(address(this));
        MockERC20(Currency.unwrap(payoutToken)).mint(address(this), reserves);
        MockERC20(Currency.unwrap(payoutToken)).approve(address(venue), type(uint256).max);
        venue.fundReserves(payoutToken, reserves);
    }

    // ---------------------------------------------------------------------------------------
    // Swap / delta helpers
    // ---------------------------------------------------------------------------------------

    function _amountOutFromDelta(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        return out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @notice The exact output a plain-AMM swap of `amountIn` would produce against the current
    /// pool state — measured by actually doing the swap in a reverted snapshot, so it is the real
    /// number, not an estimate.
    function _ammReferenceOut(PoolKey memory k, bool zeroForOne, int256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        BalanceDelta d = swap(k, zeroForOne, amountIn, ZERO_BYTES);
        out = _amountOutFromDelta(d, zeroForOne);
        vm.revertToState(snap);
    }

    // ---------------------------------------------------------------------------------------
    // Event decoders
    // ---------------------------------------------------------------------------------------

    /// @dev Decodes the single `VenueRouted` event (5 non-indexed uint256 fields) from `emitter`.
    function _decodeVenueRouted(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (uint256 amountIn, uint256 ammAmountOut, uint256 venueAmountOut, uint256 lpShare, uint256 traderShare)
    {
        bytes32 sig = keccak256("VenueRouted(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
        revert("VenueRouted event not found");
    }

    function _countVenueSkipped(Vm.Log[] memory logs, address emitter, bytes32 reason)
        internal
        pure
        returns (uint256 n)
    {
        bytes32 sig = keccak256("VenueSkipped(bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig) {
                bytes32 got = abi.decode(logs[i].data, (bytes32));
                if (got == reason) n++;
            }
        }
    }

    function _hasVenueRouted(Vm.Log[] memory logs, address emitter) internal pure returns (bool) {
        bytes32 sig = keccak256("VenueRouted(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig) return true;
        }
        return false;
    }
}
