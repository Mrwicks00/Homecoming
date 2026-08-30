# TODO — Full four-tier test suite (~200 tests)  ✅ DONE

Plan: `/home/user/.claude/plans/linked-riding-wombat.md`
Baseline: 18 tests / 4 suites. **Final: 201 tests / 10 suites, all green.**

## Config + src
- [x] `foundry.toml` — `[fuzz] runs=256`, `[invariant] runs=256 depth=32 fail_on_revert=false`
      (dropped the planned `[profile.lite]` — no-IR profile is impossible here, `CowRecaptureReceiver`
      hits "stack too deep" without `via_ir`)
- [x] `src/libraries/ReferencePriceLib.sol` — `_compressToTickLower` `private` → `internal` (only src change)

## Test utilities (`test/util/`)
- [x] `HomecomingTestBase.sol` — pool/hook setup + delta/event decoders (pulled out of the duplicated inline copies)
- [x] `MaliciousVenueAdapter.sol` — revert / ok=false / underpay / inflated-claim / reentrant modes
- [x] `ReferencePriceLibHarness.sol`, `CurrencySettleHarness.sol`

## Unit tier
- [x] `ImprovementLib.t.sol` — 6 → 42
- [x] `ReferencePriceLib.t.sol` — 5 → 33
- [x] `EligibilityLib.t.sol` — NEW, 24

## Integration tier
- [x] `HomecomingHook.t.sol` — 4 → 37
- [x] `CowRecaptureReceiver.t.sol` — 3 → 29
- [x] `CurrencySettleLib.t.sol` — NEW, 7
- [x] `HooksTrampoline.t.sol` — NEW, 9  (the vendored dep was untested)
- [x] `CowLegEndToEnd.t.sol` — NEW, 8  (settlement stub → HooksTrampoline → receiver → donate)

## Invariant tier
- [x] `HomecomingHook.invariant.t.sol` + `handlers/HomecomingHookHandler.sol` — 6 invariants,
      8192 handler calls/run, 0 reverts (INV1/INV3/INV4/INV5)
- [x] `CowRecaptureReceiver.invariant.t.sol` + `handlers/CowReceiverHandler.sol` — 5 invariants
      (no fund retention, pull ≤ allowance, bystander never debited, donated == pulled)

## Docs
- [x] README §12 rewritten (201 tests / 10 suites, four-tier breakdown) + §11 layout tree
- [x] SECURITY §8 — "no invariant harness" caveat replaced with what the suites now assert
- [x] MECHANISM §9 — INV1–INV6 → enforcing-test mapping table
- [x] ARCHITECTURE_VALIDATION §8 — `via_ir = true` (required) note + build-time consequence

## Verify
- [x] `forge build` clean (~90s, via_ir)
- [x] `forge test` — 201 passed / 0 failed / 10 suites
- [x] break-check: disabled the `ImprovementLib` cap → 7 cap tests fail (incl. the fuzz property); reverted
- [x] `git diff --stat src/` = only the 1-word `ReferencePriceLib` change
- [x] `forge fmt test/` clean

## Review

**Outcome:** grew the suite from 18 → 201 tests across all four tiers, with new invariant suites
covering both `HomecomingHook` and `CowRecaptureReceiver` as the user requested.

**Deviations from plan:**
- No `[profile.lite]` fast profile — `via_ir` is mandatory for this codebase (documented in
  `foundry.toml` + ARCHITECTURE_VALIDATION §8). Builds stay ~90s.
- Added two integration files not in the original plan (`HooksTrampoline.t.sol`,
  `CowLegEndToEnd.t.sol`) — the vendored trampoline and the real end-to-end CoW call path were
  completely untested and are higher-value than padding the lib suites further.
- Invariant handlers use `PoolModifyLiquidityTestNoChecks` (the checked router `assert`s on a
  zero-delta `liquidityDelta: -1`, which bounded fuzzing hits constantly).

**Notable:** the break-check confirms the cap tests have teeth. The hook invariant runs 8192
handler calls per property with **0 reverts** — meaning `swapExactIn` (which routes through the
venue path with random adapter quality) never once caused a stuck trade (INV4), and real recapture
+ `donate()` fired across the run (`invariant_routedImpliesImprovement` passing).
