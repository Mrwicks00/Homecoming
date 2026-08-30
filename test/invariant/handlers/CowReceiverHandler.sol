// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {CowRecaptureReceiver} from "../../../src/integrations/cow/CowRecaptureReceiver.sol";
import {ReferencePriceLib} from "../../../src/libraries/ReferencePriceLib.sol";

/// @notice Stateful handler for CowRecaptureReceiver invariant testing. Multiple actors set
/// allowances up and down and drive `recapture` with random claims; one actor (`bystander`)
/// never approves. Ghost counters track pulls and donations for aggregate conservation checks.
contract CowReceiverHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTestNoChecks public immutable modifyRouter;
    CowRecaptureReceiver public immutable receiver;

    PoolKey internal key;
    Currency internal c0;
    Currency internal c1;
    bytes32 internal constant SALT = keccak256("homecoming.cow.handler.position");

    address public immutable bystander;
    address[3] public actors; // [0],[1] approve; [2] == bystander, never approves

    uint256 public totalPulled;
    uint256 public totalDonated;
    uint256 public recaptureCalls;
    uint256 public successfulRecaptures;
    mapping(address => uint256) public pulledFrom;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTestNoChecks _modifyRouter,
        CowRecaptureReceiver _receiver,
        PoolKey memory _key
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        modifyRouter = _modifyRouter;
        receiver = _receiver;
        key = _key;
        c0 = _key.currency0;
        c1 = _key.currency1;

        actors[0] = makeAddr("cow_actor_0");
        actors[1] = makeAddr("cow_actor_1");
        bystander = makeAddr("cow_bystander");
        actors[2] = bystander;

        MockERC20(Currency.unwrap(c0)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c0)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(_swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(_modifyRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(_modifyRouter), type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            MockERC20(Currency.unwrap(c0)).mint(actors[i], 1e24);
            MockERC20(Currency.unwrap(c1)).mint(actors[i], 1e24);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _tokenOut(bool zeroForOne) internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(zeroForOne ? c1 : c0));
    }

    // ---------------------------------------------------------------------------------------

    function setAllowance(uint256 actorSeed, uint256 amtSeed, bool zeroForOne) external {
        address a = _actor(actorSeed);
        if (a == bystander) return; // the bystander never approves — that is the whole point
        uint256 amt = bound(amtSeed, 0, 20 ether);
        vm.prank(a);
        _tokenOut(zeroForOne).approve(address(receiver), amt);
    }

    function recapture(uint256 actorSeed, uint256 amtInSeed, uint256 bpsSeed, bool zeroForOne) external {
        address a = _actor(actorSeed);
        uint256 amountIn = bound(amtInSeed, 1e14, 4e20);
        uint256 bps = bound(bpsSeed, 0, 6_000);

        // craft a venueOut relative to the receiver's own live quote so pulls actually happen
        (uint160 sp, int24 tick,, uint24 fee) = manager.getSlot0(key.toId());
        uint128 liq = manager.getLiquidity(key.toId());
        ReferencePriceLib.Quote memory q =
            ReferencePriceLib.quoteExactInSingleRange(sp, tick, key.tickSpacing, liq, fee, amountIn, zeroForOne);
        uint256 venueOut = q.withinCurrentRange ? q.amountOut + (q.amountOut * bps) / 10_000 : amountIn;

        MockERC20 tOut = _tokenOut(zeroForOne);
        uint256 balBefore = tOut.balanceOf(a);

        vm.recordLogs();
        try receiver.recapture(key, zeroForOne, a, amountIn, venueOut) {
            uint256 pulled = balBefore - tOut.balanceOf(a);
            totalPulled += pulled;
            pulledFrom[a] += pulled;
            if (pulled > 0) {
                successfulRecaptures++;
                totalDonated += pulled; // every pulled unit is donate()d in the same call
            }
        } catch {}
        recaptureCalls++;
    }

    function movePool(uint256 amtSeed, bool zeroForOne) external {
        uint256 amt = bound(amtSeed, 1e15, 2e21);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function addLiquidity(uint256 seed) external {
        uint256 delta = bound(seed, 1e18, 1e22);
        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(delta), salt: SALT}),
            ""
        );
    }

    function bystanderStartBalance0() external view returns (uint256) {
        return 1e24;
    }
}
