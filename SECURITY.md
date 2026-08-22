# SECURITY.md — Homecoming Threat Model & Findings

Adversarial review of both deployments (`HomecomingHook` on Unichain Sepolia, `CowRecaptureReceiver` on Ethereum Sepolia), organized by the threat categories in the engineering brief §23. Findings are graded by what actually happens if exploited, not by abstract severity labels — every entry says exactly what an attacker gets, and what backstops it.

---

## 1. Findings caught and fixed during implementation

These are not hypothetical — each was reproduced or reasoned through concretely while building, and the fix is in the shipped code.

### 1.1 [FIXED] Reference-price boundary bug — exact tick-spacing boundary + zeroForOne

**What happened:** `ReferencePriceLib` computes a swap's cell boundary as `sqrtPriceAtTick(tickLower)` for `zeroForOne` trades. When the pool's current price sits *exactly* on a tick-spacing multiple (e.g. a freshly initialized 1:1 pool at tick 0), `tickLower == tick`, so the computed target equals the current price — zero room to move. Every `zeroForOne` trade was therefore reported as "crosses the cell," permanently disabling the eligible/recapture path for any pool sitting exactly on a boundary.

**How it was caught:** the Core integration test (`test_recapture_whenVenueBeatsReference`) failed against the real `PoolManager` — not a unit test in isolation, the actual end-to-end path.

**Fix:** `ReferencePriceLib.sol` now detects `sqrtPriceX96 == sqrtPriceAtTick(tickLower)` and shifts the target one tick-spacing further down, mirroring the exact boundary subtlety Uniswap documents on `IPoolManager.donate()` itself ("the sqrtPrice of a pool can be at the lower boundary of tick n, but slot0.tick is already n-1"). Regression tests (`test_regression_exactBoundaryTick_*`) pin this behavior.

**Why it matters beyond the fix:** it's a concrete demonstration of why §5/§17's demand for exact, non-approximated reference pricing is not pedantry — a subtly wrong boundary doesn't produce a slightly-off number, it silently disables the entire mechanism at the single most common pool state (a freshly initialized 1:1 pool).

### 1.2 [FIXED-BY-REDESIGN] CoW leg: shared-balance sweep vulnerability

**What happened:** the first design for `CowRecaptureReceiver` had the trader's CoW order route its output *to the receiver contract*, which would then forward a trader-specified share to a caller-chosen `trader` address. Once the recipient address became a caller-supplied parameter, the vulnerability is direct: `recapture()` is necessarily permissionless (it's invoked via CoW's `HooksTrampoline`, whose docs state explicitly that a call arriving through it must not be assumed trustworthy — see FEASIBILITY.md Q12). Any address could call `recapture()` naming *itself* as `trader`, with `amountInClaimed` manipulated to zero out the LP share, and drain whatever balance happened to be sitting in the shared receiver — including another trader's not-yet-swept proceeds, if two orders using the receiver settled in the same CoW batch (post-hooks fire after *all* orders in a batch settle, so cross-order commingling is a real, not hypothetical, scenario).

**Fix — architectural, not patched:** the receiver never custodies trade proceeds. The trader receives their real CoW-settled output directly and normally, exactly as in any CoW trade with no hook at all. `recapture()` only ever *pulls*, via a standard ERC20 `transferFrom`, an amount bounded by what the named `trader` has themselves pre-approved — so the worst a malicious caller can do is trigger a pull that was already fully authorized by its victim, for an amount computed from a real (if trader-reported) formula, paid only to the pool via `donate()`. There is no code path that sends funds to a caller-chosen address. See `CowRecaptureReceiver.sol`'s contract-level NatSpec for the full trust-model writeup.

**Residual limitation (not a vulnerability, a documented trust bound):** because the receiver cannot independently observe a CoW order's real sell/buy amounts (unlike `HomecomingHook`, which reads `SwapParams` directly), `amountInClaimed`/`venueAmountOutClaimed` are self-reported by the trader. A dishonest trader can under-report to shrink their own LP contribution to zero. They cannot inflate it to extract more than their own pre-approved allowance, and they cannot affect anyone else's funds. This bound is inherent to CoW's post-hook architecture, not a bug in this contract — see MECHANISM.md §5 addendum.

---

## 2. Venue / adapter threats (Core leg — `IPrivateVenueAdapter`)

| Threat | Mitigation |
|---|---|
| Adapter reports `success=true` with a fabricated `amountOutClaimed` | Never trusted — `attemptVenueRoute` measures `tokenOut.balanceOf(address(this))` before/after the adapter call and uses only the realized delta (`HomecomingHook.sol`, `attemptVenueRoute`) |
| Adapter reverts, or underperforms after already receiving `amountIn` | The entire venue attempt runs inside a self-call (`this.attemptVenueRoute(...)`) wrapped in `try/catch` in `_beforeSwap`. A revert unwinds every state change made inside — the `take()`, the transfer to the adapter, everything — and control falls through to `ZERO_DELTA`, i.e. plain AMM execution. Verified by `test_fallsBackToAmm_whenVenueWorseThanReference`, which asserts the trader's output is *byte-identical* to a no-adapter swap, not merely "not reverted." |
| Adapter is malicious and tries to reenter the hook or PoolManager mid-`trySettle` | `attemptVenueRoute` is guarded (`onlySelf`, i.e. `msg.sender == address(this)`) so it cannot be invoked out-of-band; PoolManager's own transient-storage lock rejects overlapping/malformed unlock sequences. The hook holds no long-lived mutable state that a reentrant call could corrupt mid-flight — `config`/`venueAdapter` are read once at the top of `_beforeSwap` and not re-read afterward. |
| Adapter pays out in the wrong token, or a different amount than the pair implies | `tokenOut` is derived from the pool's own `PoolKey` + swap direction, never from adapter or caller input; the balance check is scoped to exactly that currency. |
| Native-currency (`address(0)`) pools | Explicitly out of scope — `_beforeSwap` short-circuits to plain AMM whenever either currency is native, before any venue logic runs. Native flash-accounting (msg.value handling) is real complexity intentionally not taken on for this build; see README.md limitations. |

## 3. CoW-specific threats (leg B)

| Threat | Mitigation |
|---|---|
| Replay of a `recapture()` call across chains / wrong settlement contract | `CowRecaptureReceiver` is deployed once per chain, immutably bound to a specific `IPoolManager` at construction; it has no signature-verification surface to replay (see below) — it only ever moves the caller-named trader's *currently* approved allowance, so a stale/replayed call either pulls nothing (allowance already spent) or nothing changes beyond what the trader still permits. |
| A malicious actor calls `recapture()` for a trader who never intended to participate | Costs the trader nothing beyond what they explicitly pre-approved via `ERC20.approve` — approval is the trader's own opt-in gate. A trader who wants zero exposure simply never approves the contract. |
| `HooksTrampoline` gas-limits the call and it silently fails | By CoW's own design (see FEASIBILITY.md Q12 sources) — hook execution isn't guaranteed and the underlying order still settles either way. `recapture()` has no side effects until its final `transferFrom`/`donate`, so a truncated/failed execution leaves no partial state. |
| Chain-ID / wrong-deployment confusion (brief §25) | `CowRecaptureReceiver` holds an immutable `poolManager` reference set at construction; it is deployed once on Ethereum Sepolia only, alongside CoW's own canonical, chain-specific `GPv2Settlement`/`HooksTrampoline` — there is no cross-chain message or signature to misroute. |

## 4. `donate()` / LP-accounting threats

| Threat | Mitigation |
|---|---|
| JIT liquidity added immediately before a `donate()` call to capture a disproportionate share, then withdrawn after | This is a **documented, unmitigated limitation**, not something this build claims to solve — `IPoolManager.donate()`'s own NatSpec warns explicitly that donations are JIT-frontrunnable. Homecoming inherits this exactly as any other donate-based mechanism does. It is out of scope to build MEV-resistant donation timing for a hackathon build; README.md states this plainly rather than claiming LPs broadly benefit. |
| "LPs" being read as "all LPs in the pool" | Corrected throughout the docs: `donate()` pays only **in-range liquidity at `slot0.tick`** at the moment of the call (`ARCHITECTURE_VALIDATION.md` §4). Out-of-range LPs get nothing from a given donation. |
| Donation amount exceeding what the hook/receiver actually holds | Both `HomecomingHook.attemptVenueRoute` and `CowRecaptureReceiver.recapture` compute `lpShare` strictly from realized balances (venue balance delta, or a bounded `transferFrom`) *before* calling `donate()`/`settle()` — there is no path where the donated amount exceeds funds actually in hand (INV5, MECHANISM.md §9). |
| Rounding manipulation (donating fractional-unit dust in the caller's favor) | `ImprovementLib.splitImprovement` rounds `lpShare` down via integer division; the residual (including all rounding dust) flows to the trader/venue side, never re-computed to favor the LP side or vice versa — fuzz-tested (`testFuzz_INV1_lpShareNeverExceedsImprovement`, `testFuzz_lpShareBoundedByCapOfAmountIn`). |

## 5. Trader / hookData threats

| Threat | Mitigation |
|---|---|
| Trader fabricates a "venue said X" claim in `hookData` to manufacture improvement | `HomecomingHook`'s `_beforeSwap` takes no venue-output value from `hookData` at all — the only externally supplied numbers that matter (`amountIn`, `zeroForOne`) come from `SwapParams`, which the PoolManager itself enforces as the actual swap being executed, not from arbitrary caller data. |
| Trader manipulates pool state pre-swap to inflate the reference price they'll be compared against | The reference price is computed from the *same* live pool state the actual swap executes against, in the *same* transaction (`StateLibrary` reads happen at the top of `_beforeSwap`, immediately before use) — there's no stale/cacheable snapshot to front-run. Moving the pool state costs real capital and real slippage, proportional to any gain, same as any pool-price manipulation attack against Uniswap itself. |
| CoW-leg trader under-reports `amountInClaimed`/`venueAmountOutClaimed` | Covered in §1.2 — bounded to "this trader contributes less than a fully honest report would produce," never to fund extraction. |
| Exact-output swaps used to dodge/exploit the routing logic | Out of scope by construction — `_beforeSwap` returns `ZERO_DELTA` immediately for any `amountSpecified >= 0` (exact-output), before any eligibility or venue logic runs. |

## 6. Hook-level / reentrancy / accounting threats

| Threat | Mitigation |
|---|---|
| Nested `PoolManager` calls (donate inside beforeSwap, itself inside swap) corrupting flash-accounting | Verified empirically, not just reasoned about — `test_recapture_whenVenueBeatsReference` exercises exactly this nested `take → adapter → settle → donate → settle` sequence against the real `PoolManager` and asserts exact conservation of value. The pattern itself (calling `take`/`settle` from inside `beforeSwap`) mirrors v4-core's own reference `CustomCurveHook.sol` test fixture. |
| `attemptVenueRoute` called directly by an arbitrary address (it's `external`) | Reverts (`OnlySelf`) unless `msg.sender == address(this)` — it can only run as the try/catch-wrapped sub-call from `_beforeSwap` itself. |
| Governance key compromise (`setVenueAdapter`, `setConfig`) | Single EOA/multisig-controlled `governance` address for the hackathon build — no timelock, no multisig requirement enforced on-chain. **Documented limitation**, not production-hardened; see README.md "what would be required for production." |
| Hook permission/address mismatch at deploy time | `BaseHook`'s constructor calls `Hooks.validateHookPermissions`, which reverts unless the deployed address's low 14 bits exactly match `getHookPermissions()` — deployment is impossible without a correctly CREATE2-mined salt (`HookMiner`), enforced by the framework itself, not by this project's discipline alone. |

## 7. Token-level threats

| Threat | Mitigation |
|---|---|
| Fee-on-transfer tokens | Not accounted for — `attemptVenueRoute` assumes `transfer`/`transferFrom` moves the full nominal amount. A fee-on-transfer `tokenOut` would cause the hook's post-transfer balance check to under-read, which the code already treats conservatively (it would look like a worse venue fill than claimed, triggering the revert-and-fallback path) — so the failure mode is "recapture doesn't fire," not "value is fabricated or lost," but this is not exhaustively tested and such tokens should be excluded from any real pool this hook governs. |
| Rebasing tokens | Same class of risk as above; not supported, not tested. Out of scope. |
| Non-standard ERC20 return values (no return value on `transfer`) | `IERC20Minimal.transfer`/`transferFrom` are called expecting a `bool` return per the interface; a token that returns nothing would revert the ABI-decode, which — inside `attemptVenueRoute`'s try/catch — degrades safely to the AMM fallback rather than corrupting state. Direct `IERC20Minimal` calls in `CowRecaptureReceiver` are not try/catch-wrapped in the same way, since a `recapture()` failure has no partial state to clean up (see §3) — but a non-standard token there would simply cause `recapture()` to revert harmlessly, leaving the trader's already-completed CoW trade untouched. |
| Malicious ERC20 with reentrant callback logic (ERC777-style) | Out of scope by policy — Homecoming targets standard ERC20 pairs only; this is stated as a scope limitation rather than defended against with a reentrancy guard, consistent with v4-core's own general hook-security posture (hooks are not assumed safe against arbitrary token behavior). |

## 8. What this review did **not** cover

- Formal verification of `ReferencePriceLib`/`ImprovementLib` beyond fuzz testing (256 runs per property; no symbolic execution or invariant-testing harness with stateful sequences was built for the hackathon timeline).
- A real economic/game-theoretic analysis of whether `LP_RECAPTURE_RATE_BPS` is set at a value that keeps solvers/venues economically willing to participate (§22) — the configured rate is a placeholder, not a researched equilibrium value.
- Any external audit. This is hackathon-stage code; treat every finding above as "known and mitigated to the stated degree," not as a certification of safety for real funds.
