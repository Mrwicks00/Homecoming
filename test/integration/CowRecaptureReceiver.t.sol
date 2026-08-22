// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {CowRecaptureReceiver} from "../../src/integrations/cow/CowRecaptureReceiver.sol";
import {HomecomingTypes} from "../../src/libraries/HomecomingTypes.sol";

contract CowRecaptureReceiverTest is Test, Deployers {
    CowRecaptureReceiver receiver;
    HomecomingTypes.Config cfg;
    address trader = makeAddr("cow_trader");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        cfg = HomecomingTypes.Config({
            minAmountIn: 1,
            minLiquidity: 0,
            lpRecaptureBps: 5000,
            maxImprovementBpsOfAmountIn: 1000
        });

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );

        receiver = new CowRecaptureReceiver(manager, cfg, address(this));
    }

    function _ammReference(int256 amountIn) internal returns (uint256 amountOut) {
        uint256 snapshot = vm.snapshotState();
        BalanceDelta d = swap(key, true, amountIn, ZERO_BYTES);
        amountOut = uint256(uint128(d.amount1()));
        vm.revertToState(snapshot);
    }

    function test_recapture_pullsOnlyLpShare_fromTraderAllowance() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammReference(amountIn);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000; // 5% better

        MockERC20(Currency.unwrap(currency1)).mint(trader, venueOut);
        vm.prank(trader);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);

        uint256 traderBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.recordLogs();
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);

        uint256 traderBalAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);
        uint256 pulled = traderBalBefore - traderBalAfter;

        uint256 improvement = venueOut - ammOut;
        uint256 expectedLpShare = (improvement * cfg.lpRecaptureBps) / 10_000;

        assertEq(pulled, expectedLpShare, "must pull exactly the computed LP share, no more");
        assertLt(pulled, venueOut, "must never pull the trader's full realized amount");
    }

    function test_recapture_pullsNothing_whenAllowanceIsZero() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammReference(amountIn);
        uint256 venueOut = ammOut + (ammOut * 500) / 10_000;

        MockERC20(Currency.unwrap(currency1)).mint(trader, venueOut);
        // no approval granted

        vm.expectRevert();
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);
    }

    function test_recapture_skipsSilently_whenVenueNotBetterThanAmm() public {
        int256 amountIn = -1e18;
        uint256 ammOut = _ammReference(amountIn);
        uint256 venueOut = ammOut - (ammOut * 500) / 10_000; // 5% worse

        MockERC20(Currency.unwrap(currency1)).mint(trader, ammOut);
        vm.prank(trader);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), type(uint256).max);

        uint256 before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);
        receiver.recapture(key, true, trader, uint256(-amountIn), venueOut);
        uint256 afterBal = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);

        assertEq(before, afterBal, "a worse-than-AMM claim must never pull any funds");
    }
}
