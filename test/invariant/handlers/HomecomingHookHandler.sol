// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HomecomingHook} from "../../../src/HomecomingHook.sol";
import {HomecomingTypes} from "../../../src/libraries/HomecomingTypes.sol";
import {MockVenueAdapter} from "../../../src/integrations/MockVenueAdapter.sol";

/// @notice Stateful handler for HomecomingHook invariant testing. Every entrypoint is a bounded,
/// realistic action a real actor could take: swap (random size/direction/venue quality), add or
/// remove the handler's own liquidity, retune config, flip the adapter on/off. Ghost counters
/// accrue realized Improvement and realized LP donations from the emitted events.
contract HomecomingHookHandler is Test {
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTestNoChecks public immutable modifyRouter;
    HomecomingHook public immutable hook;
    MockVenueAdapter public immutable venue; // owned by this handler
    address public immutable gov;

    PoolKey internal key;
    Currency internal c0;
    Currency internal c1;
    bytes32 internal constant HANDLER_SALT = keccak256("homecoming.hook.handler.position");

    // ghosts
    uint256 public totalImprovement;
    uint256 public totalLpDonated;
    uint256 public swaps;
    uint256 public routedSwaps;
    uint256 public handlerLiquidity; // net liquidity this handler has added
    bool public sawSwapRevert;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTestNoChecks _modifyRouter,
        HomecomingHook _hook,
        address _gov,
        PoolKey memory _key
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        modifyRouter = _modifyRouter;
        hook = _hook;
        venue = new MockVenueAdapter(address(this));
        gov = _gov;
        key = _key;
        c0 = _key.currency0;
        c1 = _key.currency1;

        MockERC20(Currency.unwrap(c0)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c0)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(_modifyRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(_modifyRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------

    function swapExactIn(uint256 amountSeed, uint256 bpsSeed, bool zeroForOne) external {
        uint256 amountIn = bound(amountSeed, 1e14, 3e21);
        int256 bps = int256(bound(bpsSeed, 0, 8_000)) - 2_000; // venue fills -20% .. +60% vs reference

        (Currency tIn, Currency tOut) = zeroForOne ? (c0, c1) : (c1, c0);
        vm.startPrank(gov);
        hook.setVenueAdapter(address(venue));
        vm.stopPrank();
        venue.configure(tIn, tOut, true, bps);
        _refillVenue(tOut);

        vm.recordLogs();
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            _accrueFromLogs(vm.getRecordedLogs());
        } catch {
            sawSwapRevert = true;
        }
        swaps++;
    }

    function swapNoAdapter(uint256 amountSeed, bool zeroForOne) external {
        uint256 amountIn = bound(amountSeed, 1e14, 3e21);
        vm.startPrank(gov);
        hook.setVenueAdapter(address(0));
        vm.stopPrank();
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch {
            sawSwapRevert = true;
        }
        swaps++;
    }

    function addLiquidity(uint256 seed) external {
        uint256 delta = bound(seed, 1e18, 5e22);
        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(delta), salt: HANDLER_SALT
            }),
            ""
        );
        handlerLiquidity += delta;
    }

    function removeLiquidity(uint256 seed) external {
        if (handlerLiquidity == 0) return;
        uint256 delta = bound(seed, 1, handlerLiquidity);
        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: -int256(delta), salt: HANDLER_SALT
            }),
            ""
        );
        handlerLiquidity -= delta;
    }

    function retuneConfig(uint256 lpSeed, uint256 maxSeed) external {
        vm.startPrank(gov);
        hook.setConfig(
            HomecomingTypes.Config({
                minAmountIn: 1e15,
                minLiquidity: 0,
                lpRecaptureBps: uint16(bound(lpSeed, 0, 10_000)),
                maxImprovementBpsOfAmountIn: uint16(bound(maxSeed, 0, 10_000))
            })
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------

    function _refillVenue(Currency tOut) internal {
        if (MockERC20(Currency.unwrap(tOut)).balanceOf(address(venue)) < 1e24) {
            MockERC20(Currency.unwrap(tOut)).mint(address(this), 1e24);
            MockERC20(Currency.unwrap(tOut)).approve(address(venue), type(uint256).max);
            venue.fundReserves(tOut, 1e24);
        }
    }

    function _accrueFromLogs(Vm.Log[] memory logs) internal {
        bytes32 sig = keccak256("VenueRouted(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                (, uint256 ammOut, uint256 venueOut, uint256 lpShare,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                totalImprovement += venueOut - ammOut;
                totalLpDonated += lpShare;
                routedSwaps++;
            }
        }
    }
}
