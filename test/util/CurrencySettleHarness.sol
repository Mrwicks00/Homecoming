// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CurrencySettleLib} from "../../src/libraries/CurrencySettleLib.sol";

/// @notice Exercises CurrencySettleLib.settle/take inside a real unlock() context so the
/// production copy of v4-core's settle/take pattern can be tested directly.
contract CurrencySettleHarness is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Op {
        SETTLE_SELF_THEN_TAKE, // pay in from this contract, then take it back — net zero
        SETTLE_PAYER_THEN_TAKE, // pull from `payer` via transferFrom, then take to this contract
        SETTLE_ONLY_SELF, // pay in with nothing to cover -> leaves a positive delta -> revert
        TAKE_ONLY, // take with no credit -> leaves a negative delta -> revert
        SETTLE_SELF_TAKE_MORE // take strictly more than settled -> revert
    }

    error NotManager();

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function run(Op op, Currency currency, uint256 amount, address payer) external {
        manager.unlock(abi.encode(op, currency, amount, payer));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (Op op, Currency currency, uint256 amount, address payer) = abi.decode(data, (Op, Currency, uint256, address));

        if (op == Op.SETTLE_SELF_THEN_TAKE) {
            CurrencySettleLib.settle(currency, manager, address(this), amount);
            CurrencySettleLib.take(currency, manager, address(this), amount);
        } else if (op == Op.SETTLE_PAYER_THEN_TAKE) {
            CurrencySettleLib.settle(currency, manager, payer, amount);
            CurrencySettleLib.take(currency, manager, address(this), amount);
        } else if (op == Op.SETTLE_ONLY_SELF) {
            CurrencySettleLib.settle(currency, manager, address(this), amount);
        } else if (op == Op.TAKE_ONLY) {
            CurrencySettleLib.take(currency, manager, address(this), amount);
        } else {
            CurrencySettleLib.settle(currency, manager, address(this), amount);
            CurrencySettleLib.take(currency, manager, address(this), amount + 1);
        }
        return "";
    }
}
