// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {CurrencySettleHarness} from "../util/CurrencySettleHarness.sol";

/// @notice Direct coverage for CurrencySettleLib — Homecoming's vendored copy of v4-core's
/// settle/take pattern (CurrencySettleLib.sol NatSpec) — exercised inside a real unlock() context.
contract CurrencySettleLibTest is Test, Deployers {
    CurrencySettleHarness harness;
    address payer = makeAddr("payer");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        harness = new CurrencySettleHarness(manager);

        // Give the harness and the payer working balances.
        MockERC20(Currency.unwrap(currency0)).mint(address(harness), 1_000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(payer, 1_000 ether);
        vm.prank(payer);
        MockERC20(Currency.unwrap(currency0)).approve(address(harness), type(uint256).max);
    }

    function test_settleSelfThenTake_isBalanceNeutral() public {
        uint256 before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness));
        harness.run(CurrencySettleHarness.Op.SETTLE_SELF_THEN_TAKE, currency0, 10 ether, address(0));
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness)), before, "self round-trip nets zero");
    }

    function test_settleFromPayerThenTake_movesPayerFundsToHarness() public {
        uint256 payerBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(payer);
        uint256 harnessBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness));

        harness.run(CurrencySettleHarness.Op.SETTLE_PAYER_THEN_TAKE, currency0, 25 ether, payer);

        assertEq(
            MockERC20(Currency.unwrap(currency0)).balanceOf(payer),
            payerBefore - 25 ether,
            "payer debited via transferFrom"
        );
        assertEq(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness)),
            harnessBefore + 25 ether,
            "harness credited by take"
        );
    }

    function test_settleOnly_leavesPositiveDelta_reverts() public {
        vm.expectRevert();
        harness.run(CurrencySettleHarness.Op.SETTLE_ONLY_SELF, currency0, 5 ether, address(0));
    }

    function test_takeOnly_leavesNegativeDelta_reverts() public {
        vm.expectRevert();
        harness.run(CurrencySettleHarness.Op.TAKE_ONLY, currency0, 5 ether, address(0));
    }

    function test_takeMoreThanSettled_reverts() public {
        vm.expectRevert();
        harness.run(CurrencySettleHarness.Op.SETTLE_SELF_TAKE_MORE, currency0, 5 ether, address(0));
    }

    function test_unlockCallback_onlyManager() public {
        vm.expectRevert(CurrencySettleHarness.NotManager.selector);
        harness.unlockCallback("");
    }

    function testFuzz_settleSelfThenTake_neutralForAnyAmount(uint256 amount) public {
        amount = bound(amount, 0, 1_000 ether);
        uint256 before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness));
        harness.run(CurrencySettleHarness.Op.SETTLE_SELF_THEN_TAKE, currency0, amount, address(0));
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(harness)), before);
    }
}
