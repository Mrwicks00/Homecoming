// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Production copy of v4-core's own settle/take pattern for a hook that pays or receives
/// currency directly against PoolManager's flash accounting.
/// @dev v4-core ships the equivalent logic as `CurrencySettler` under its `test/` tree
/// (test/utils/CurrencySettler.sol), used by its own reference NoOp hook (src/test/CustomCurveHook.sol).
/// That file is a test utility, not part of v4-core's published `src/` interface, so production code
/// should not depend on a dependency's test path — this is the same verified sequence, vendored into
/// Homecoming's own src/ instead. ERC-6909 claim paths are intentionally omitted: Homecoming never
/// mints/burns claim tokens, it only ever moves real ERC20 balances.
library CurrencySettleLib {
    /// @notice Pay `amount` of `currency` into the PoolManager on behalf of `payer`.
    /// @dev Must be called from inside an active unlock() context. `sync()` before the transfer is
    /// required by PoolManager to correctly checkpoint the balance and derive the caller's delta.
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount) internal {
        manager.sync(currency);
        if (payer != address(this)) {
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
        }
        manager.settle();
    }

    /// @notice Receive `amount` of `currency` from the PoolManager to `recipient`.
    /// @dev Only valid when the caller holds a positive delta (credit) for `currency` of at least
    /// `amount` — e.g. from a BeforeSwapDelta the hook returned that consumed the specified amount.
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount) internal {
        manager.take(currency, recipient, amount);
    }
}
