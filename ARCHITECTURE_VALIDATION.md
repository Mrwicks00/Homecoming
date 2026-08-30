# ARCHITECTURE_VALIDATION.md — Uniswap v4 Execution Semantics

Ground truth pulled directly from `Uniswap/v4-core` (`main`, Solidity 0.8.30-compatible, `main` branch as of 2026-08-22) and `Uniswap/v4-periphery`. Every claim below cites the source file. This gates Phase 4 implementation — nothing here is assumed from memory without being checked against real code.

---

## 1. Hook permission model

A hook's callback set is not configuration — it is **encoded in the low 14 bits of the hook contract's deployed address** and checked at construction time.

```
// Hooks.sol
ALL_HOOK_MASK              = (1 << 14) - 1
BEFORE_INITIALIZE_FLAG     = 1 << 13
AFTER_INITIALIZE_FLAG      = 1 << 12
BEFORE_ADD_LIQUIDITY_FLAG  = 1 << 11
AFTER_ADD_LIQUIDITY_FLAG   = 1 << 10
BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9
AFTER_REMOVE_LIQUIDITY_FLAG  = 1 << 8
BEFORE_SWAP_FLAG           = 1 << 7
AFTER_SWAP_FLAG            = 1 << 6
BEFORE_DONATE_FLAG         = 1 << 5
AFTER_DONATE_FLAG          = 1 << 4
BEFORE_SWAP_RETURNS_DELTA_FLAG        = 1 << 3
AFTER_SWAP_RETURNS_DELTA_FLAG         = 1 << 2
AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG    = 1 << 1
AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0
```
[`Hooks.sol`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol)

`BaseHook`'s constructor calls `Hooks.validateHookPermissions(this, getHookPermissions())`, which reverts unless the deployed address's bit pattern exactly matches the `Permissions` struct the hook declares. Consequence: **the hook's address must be CREATE2-mined** to have the right low bits before deployment (`HookMiner`, deploying through the canonical CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C`). This is a hard deployment-pipeline requirement, not an implementation nicety — get the salt wrong and the constructor reverts.

`Hooks.isValidHookAddress` additionally enforces that a `*_RETURNS_DELTA_FLAG` can only be set if its corresponding base flag (`BEFORE_SWAP_FLAG`/`AFTER_SWAP_FLAG`/etc.) is also set — you cannot return a delta from a callback you haven't enabled.

**Homecoming needs:** `BEFORE_SWAP_FLAG`, `AFTER_SWAP_FLAG`, `BEFORE_SWAP_RETURNS_DELTA_FLAG` (to consume/adjust `amountSpecified` for the AMM-fallback path — reserved for future use; the current design does not NoOp the AMM swap, see §5), `AFTER_SWAP_RETURNS_DELTA_FLAG` is **not** needed since LP recapture is done via a separate `donate()` call, not by adjusting the swap's own delta. `BEFORE_DONATE_FLAG`/`AFTER_DONATE_FLAG` are not needed — Homecoming calls `donate()`, it does not need to react to others calling it.

## 2. Exact callback signatures

From [`IHooks.sol`](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IHooks.sol):

```solidity
function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    external returns (bytes4, BeforeSwapDelta, uint24);

function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
    external returns (bytes4, int128);
```

`BeforeSwapDelta` ([`BeforeSwapDelta.sol`](https://github.com/Uniswap/v4-core/blob/main/src/types/BeforeSwapDelta.sol)) packs two `int128`s into one `int256`: upper 128 bits = delta in the **specified** currency, lower 128 bits = delta in the **unspecified** currency. If `BEFORE_SWAP_RETURNS_DELTA_FLAG` is set, `Hooks.beforeSwap` applies `getSpecifiedDelta()` to reduce the amount the core pool swap actually executes against (`Hooks.sol:266`) — this is the mechanism behind "NoOp swaps": if the hook consumes the *entire* `amountSpecified`, the pool has nothing left to swap and the hook itself must have already settled the trade (transferred tokens) during `beforeSwap`. **This only works for a settlement the hook can perform synchronously, inside its own `beforeSwap` call** — confirming FEASIBILITY.md's finding: it cannot be used to "route to CoW," because CoW cannot produce a fill synchronously inside that call.

## 3. Flash accounting / lock semantics

`PoolManager` is a singleton with transient-storage-based flash accounting. All state-mutating operations (`swap`, `modifyLiquidity`, `donate`) are only callable from inside an `unlock()` callback:

```solidity
function unlock(bytes calldata data) external returns (bytes memory);
```
[`IPoolManager.sol:114`](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol), callback interface [`IUnlockCallback.sol`](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/callback/IUnlockCallback.sol)

A normal swap is already inside an `unlock()` context by the time `beforeSwap`/`afterSwap` run (the router calls `unlock()`, which calls back into the router's `unlockCallback`, which calls `swap()`, which invokes the hook). **This means a hook can call `donate()` directly from within `afterSwap` without a second `unlock()`** — it's already inside the lock. This is confirmed by the periphery `V4Quoter`, which by contrast *does* need its own fresh `unlock()` because it's called from outside any existing lock — and Uniswap's own comment on it is explicit: `"These functions ... rely on calling non-view functions and reverting to compute the result. They are also not gas efficient and should not be called on-chain."` [`V4Quoter.sol`](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/V4Quoter.sol). **Nesting a second `unlock()` call from inside a hook that is itself running inside an existing `unlock()` context is exactly the anti-pattern that quoter comment warns against** — it is not how Homecoming should compute its AMM reference price. See §5.

## 4. `donate()` — exact semantics

```solidity
/// @dev Calls to donate can be frontrun adding just-in-time liquidity, with the aim of receiving a portion donated funds.
/// @dev This function donates to in-range LPs at slot0.tick.
function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
    external returns (BalanceDelta);
```
[`IPoolManager.sol:152-163`](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol)

Two facts must shape every LP-recapture claim in MECHANISM.md/README.md:

1. **"LPs" means only currently in-range liquidity at `slot0.tick` at the moment `donate()` executes** — not all LPs in the pool, not out-of-range LPs. Calling this "LP recapture" without that qualifier overstates the mechanism.
2. **Donations are documented as JIT-frontrunnable** — Uniswap's own interface comment warns that liquidity can be added immediately before a `donate()` call specifically to capture a share of it, then removed after. This is a required entry in SECURITY.md, not a hypothetical.

Since a swap's `afterSwap` already runs inside the same `unlock()` context as the swap itself, Homecoming's `afterSwap` can call `poolManager.donate(key, lpAmount0, lpAmount1, "")` directly — no second unlock, no reentrancy into `unlock()`. This is the real, code-grounded LP payout path (not a "donation-means-something-else" hand-wave).

## 5. Computing the AMM reference price on-chain — the real constraint

This is the sharpest edge in the whole design. Section 16 of the brief lists four options; here is which one actually survives contact with the code:

- **Option D (router/Quoter architecture) — rejected.** `V4Quoter` works by calling `poolManager.unlock()` itself and deliberately reverting to smuggle the quote out through revert data. Besides being explicitly labeled gas-inefficient and off-chain-only by its own authors, calling it from inside a hook would require nesting a fresh `unlock()` call while already inside one from the enclosing swap — undefined/fragile territory this project has no reason to rely on.
- **Option B (non-mutating quote calculation) — same problem as D**, since v4-core has no "pure" swap-quote entrypoint separate from the revert-based quoter pattern above.
- **Option A/C (math from live pool state via `StateLibrary`) — the correct approach.** [`StateLibrary.sol`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/StateLibrary.sol) reads `PoolManager`'s transient/storage slots directly via `extsload`, with no mutation and no external call: `getSlot0` (sqrtPriceX96, tick, protocolFee, lpFee), `getLiquidity`, `getFeeGrowthGlobals`, etc. This is cheap, safe to call from inside a hook mid-swap, and deterministic.

The catch: replicating the *general* concentrated-liquidity swap algorithm (crossing arbitrary numbers of initialized ticks) on-chain, correctly, is itself a large undertaking — it's most of `Pool.sol`'s `swap()` internals. Building that from scratch for a hackathon scope risks exactly the kind of unverified, easy-to-get-subtly-wrong math the brief warns against in §17 ("the comparison must be deterministic and tied to the actual pool state").

**Design decision carried into MECHANISM.md:** bound eligibility so the reference-price calculation only ever needs to hold within the pool's *current* tick (single-range constant-product math: `Δy = L·Δ(1/√P)` in that tick's liquidity, using `getSlot0`+`getLiquidity`, no tick-crossing loop required). This is enforced by making "does not cross the current tick's liquidity range" part of the eligibility check itself, not an afterthought — a swap that would move price out of the current tick is simply ineligible for the improvement/recapture path (falls back to plain AMM execution, which is always safe). This keeps the reference price exact for every trade the mechanism actually prices, instead of being an approximation on trades it can't safely handle.

## 6. External calls, reentrancy, and hook-address risk

- Hooks are ordinary contracts the `PoolManager` calls into; they can make arbitrary external calls. Multiple independent security writeups (Trail of Bits, Certora, Cyfrin — see FEASIBILITY.md sources) confirm v4 reintroduces real reentrancy surface that v2/v3 didn't have, specifically because hooks execute external calls *during* pool operations.
- Any venue-adapter call made from `beforeSwap`/`afterSwap` is exactly this risk category. Consequence for implementation: the adapter boundary must follow checks-effects-interactions, must not leave hook storage in a callable-back-into state before external calls return, and must not trust any state it read before an external call as still valid after it returns.
- For the CoW-post-hook leg (the "receiver" contract triggered by CoW's `HooksTrampoline`, not by the v4 hook) the same discipline applies in the other direction: the receiver must read realized settlement balances *after* CoW's transfers have landed, not trust any pre-computed number, before calling `donate()`.

## 7. Types used throughout implementation

`PoolKey`, `PoolId`/`PoolIdLibrary`, `BalanceDelta`, `BeforeSwapDelta`/`BeforeSwapDeltaLibrary`, `Currency`, `SwapParams`/`ModifyLiquidityParams` (now in `PoolOperation.sol`, not `IPoolManager.sol` — a real, recent-ish v4-core reorganization worth noting since older tutorials still show them nested in `IPoolManager`). Confirmed via the actual current `IHooks.sol` import list:
```solidity
import {ModifyLiquidityParams, SwapParams} from "../types/PoolOperation.sol";
```

## 8. Scaffold / dependency reality

Uniswap's own current `v4-template` (`github.com/Uniswap/v4-template`) no longer vendors `BaseHook` itself — it depends on OpenZeppelin's `uniswap-hooks` package (`lib/uniswap-hooks`, which in turn vendors `v4-core`/`v4-periphery` as nested submodules), plus `lib/hookmate` for `HookMiner`/deployment helpers. The `v4-template` `foundry.toml` uses `evm_version = "cancun"` (required — flash accounting depends on EIP-1153 transient storage, which only exists from Cancun onward) and `via_ir = false`. Homecoming follows the same dependency shape but **sets `via_ir = true`**: `CowRecaptureReceiver.recapture` exceeds the EVM stack limit without the IR pipeline (it fails to compile with "Stack too deep" otherwise). Consequence: `forge build` takes ~90s, and a no-IR fast profile is not available. Solidity `0.8.26` across `src/`.

---

## Summary of binding constraints carried forward

1. Hook address must be CREATE2-mined to encode exactly `{beforeSwap, afterSwap, beforeSwapReturnDelta}` — no more, no less.
2. `donate()` pays **in-range LPs at `slot0.tick` only**, is JIT-frontrunnable, and can be called directly from `afterSwap` (already inside the lock) — no nested `unlock()`.
3. There is no cheap, safe, on-chain "ask the AMM what it would have done" primitive for arbitrary trades — the periphery `Quoter` is explicitly off-chain-only. Homecoming computes its reference price with direct single-tick math via `StateLibrary`, and treats "does this stay within the current tick" as an eligibility gate, not an approximation to paper over.
4. `beforeSwap`'s `BeforeSwapDelta` NoOp mechanism could technically let a hook fully substitute its own settlement for the AMM's — but only for a counterparty that can settle synchronously inside that same call, which rules it out for CoW (confirmed independently by FEASIBILITY.md) and leaves it unused in the current design.
