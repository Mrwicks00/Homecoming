# MECHANISM.md — Homecoming Mechanism Design

Synthesizes FEASIBILITY.md (venue reality) and ARCHITECTURE_VALIDATION.md (v4 execution reality) into one formal, buildable mechanism. Two deployments, two chains, one shared accounting model.

## 0. Why two deployments

FEASIBILITY.md's finding forces a split that the original single-hook brief did not anticipate:

| | **Homecoming Core** | **Homecoming CoW Leg** |
|---|---|---|
| Chain | Unichain Sepolia (brief's target) | Ethereum Sepolia (only chain with both real CoW *and* v4-core) |
| Trigger | v4 swap (`beforeSwap`/`afterSwap`) | CoW settlement post-hook (`GPv2Settlement` → `HooksTrampoline`) |
| Venue leg | None real — `MockVenueAdapter` only, explicitly labeled | Real CoW Protocol, canonical `GPv2Settlement` |
| What's real | Eligibility, AMM reference pricing, `donate()` recapture, fallback — all real v4 mechanics | Real signed CoW order, real off-chain solver competition, real settlement, real recapture |
| What's simulated | The venue fill itself (mock, for demo determinism) | Nothing — this leg is either genuinely live or it doesn't run |

These are not two versions of the same claim. Core proves the v4-side mechanics are correct and safe. The CoW leg proves the "real venue" claim is not fabricated, on the one chain where it actually can be. README.md must keep these visually and textually separate at all times — this is the direct implementation of §30/§37's mock-vs-real discipline.

---

## 1. Actors

- **Trader** — initiates a swap (Core) or signs a CoW order (CoW Leg).
- **LP** — supplies liquidity to the Unichain Sepolia / Ethereum Sepolia v4 pool. Recapture recipient is *in-range LPs at `slot0.tick` at donation time* (ARCHITECTURE_VALIDATION.md §4) — not "LPs" unqualified.
- **Solver** (CoW Leg only) — off-chain competitor who wins the batch auction and submits `GPv2Settlement.settle()`.
- **Homecoming Hook** (Core) — the v4 hook contract on Unichain Sepolia.
- **Recapture Receiver** (CoW Leg) — the contract named as a CoW post-hook target; called atomically inside the solver's settlement transaction.
- **Keeper/anyone** — no privileged keeper role exists; both `afterSwap` and the CoW post-hook are triggered by the actor already causing the transaction (trader/solver), not by a separate permissioned party.

## 2. What is being routed

Precisely scoped, per §6 of the brief:

- **Exact-input, single-hop, single-pair swaps only.** Exact-output is out of scope (doubles the reference-pricing surface for no hackathon-relevant benefit).
- **One pool per deployment** for the hackathon (one Unichain Sepolia pool for Core, one Ethereum Sepolia pool for the CoW Leg) — not a generic multi-pool router.
- Eligibility additionally requires the trade to stay within the pool's **current tick's liquidity range** (ARCHITECTURE_VALIDATION.md §5) — this is what makes the reference-price math exact rather than approximate.

## 3. Eligibility — objective, not an intent classifier

Per §20/§21, Homecoming never claims to know a trader is "benign." Eligibility is a deterministic routing policy:

```
eligible(amountIn, pool) :=
    amountIn >= MIN_SIZE
    AND amountIn <= MAX_SIZE_FOR_TICK       // stays within slot0.tick's liquidity range
    AND pool.liquidity >= MIN_LIQUIDITY
    AND tokenPair == SUPPORTED_PAIR
```

`MAX_SIZE_FOR_TICK` is computed from live `StateLibrary.getSlot0`/`getLiquidity` data: the largest `amountIn` that would not move `sqrtPriceX96` past the current tick's boundary, using the standard concentrated-liquidity formula `Δ(1/√P) = Δy / L` (token1-in) or the token0 analogue. This bound is what makes the AMM reference price in §6 exact instead of an approximation glossed over as "close enough."

## 4. Routing / fallback decision tree (Core, realized on Unichain Sepolia)

```
beforeSwap
  │
  ├─ ineligible → AMM (no hook involvement beyond a no-op return)
  │
  └─ eligible
       │
       └─ hookData carries a venue quote claim?
            │
            ├─ no / malformed → AMM
            │
            └─ yes → record claim, DO NOT trust it yet
                 (validation + comparison happens in afterSwap,
                  against REALIZED balances, never the claim itself)

[core AMM swap executes — Homecoming does not NoOp it; see ARCHITECTURE_VALIDATION §5:
 NoOp requires a synchronous settlement counterparty, which no real venue provides here]

afterSwap
  │
  ├─ no venue leg was actually settled this tx (true for all real Unichain Sepolia traffic,
  │  since no real venue reaches this chain) → nothing to recapture, return
  │
  └─ MockVenueAdapter test/demo path only:
       adapter.realizedFill() read AFTER adapter's own settlement call, not caller-supplied
       │
       ├─ invalid / worse than AMM output → discard, no payout (AMM result already stands)
       │
       └─ superior to AMM's realized `delta` for this swap → compute Improvement (§6),
            split (§7), poolManager.donate(lpShare0, lpShare1, "") — already inside
            the swap's unlock() context, no nested unlock needed (ARCHITECTURE_VALIDATION §3)
```

**Honest framing:** on Unichain Sepolia, because no real venue is reachable, this flow's "eligible → venue → recapture" branch only ever executes against the mock adapter in tests/demo. Every real swap against the deployed Core hook takes the AMM path, identically to a hook-less pool, which is the correct, honest behavior given §42's invariant ("never make the trader worse off") and the fact that there is nothing better to route to.

## 5. Settlement flow (CoW Leg, realized on Ethereum Sepolia)

**Revision note:** an earlier draft of this section had the trader's CoW order route its output
*to the receiver contract*, which would then forward a caller-specified share to a caller-named
`trader` address. Implementing it surfaced a real vulnerability: since `recapture()` is necessarily
permissionless (CoW's own docs warn that a call arriving via `HooksTrampoline` must not be assumed
trustworthy — FEASIBILITY.md Q12), any caller could name *themselves* as `trader` and drain whatever
balance was sitting in the shared receiver, including another order's not-yet-swept proceeds if two
orders settled in the same batch. The corrected, shipped design below is pull-based instead — see
`CowRecaptureReceiver.sol` NatSpec and SECURITY.md §1.2 for the full writeup.

```
Trader signs CoW order
  receiver = trader's own wallet (NOT the recapture contract — trader is paid normally, directly)
  appData → post-hook = RecaptureReceiver.recapture(poolKey, zeroForOne, trader,
                                                      amountInClaimed, venueAmountOutClaimed)
  │
  ▼
Off-chain solver competition (CoW orderbook, api.cow.fi/sepolia)
  │
  ▼
Winning solver calls GPv2Settlement.settle() [solver's own tx]
  │
  ├─ trader's order settled: trader receives their REAL output DIRECTLY, exactly as any
  │  ordinary CoW trade with no hook at all — the receiver contract never custodies it
  │
  └─ post-hook fires atomically via HooksTrampoline:
       RecaptureReceiver.recapture(key, zeroForOne, trader, amountInClaimed, venueAmountOutClaimed)
         │
         1. reads live Ethereum-Sepolia v4 pool state via StateLibrary
            (getSlot0, getLiquidity) to compute the AMM counterfactual (§6) against the
            trader's self-reported amountInClaimed — see trust-model note below
         2. computes Improvement, LP share (§7), from venueAmountOutClaimed vs that reference —
            both self-reported by the trader (the receiver has no privileged view into the
            order's real amounts, unlike Core's direct SwapParams access)
         3. pulls ONLY lpShare, via a standard ERC20 transferFrom bounded by the trader's own
            pre-approved allowance — never more, never from anyone else
         4. poolManager.unlock(...) → donate(key, share0, share1, "")
            (fresh unlock here IS correct and required — the CoW settlement tx
             never touched the v4 pool's lock at all, unlike Core's afterSwap case)
```

This is the architecture FEASIBILITY.md Q1/Q12 identified as the only real composition: **control
flows from CoW settlement into the pool**, never the reverse. But unlike Core (which observes real
swap amounts trustlessly via `SwapParams`), the receiver cannot independently verify a CoW order's
real sell/buy amounts — `amountInClaimed`/`venueAmountOutClaimed` are trader-self-reported. The
design bounds the consequence of that instead of pretending it away: a dishonest trader can only
ever shrink their own LP contribution (down to zero), never extract funds from LPs, the pool, or any
other trader — every pull is capped by the named trader's own pre-approved allowance, and every
payout goes only to the pool via `donate()`, never to a caller-chosen address. This is a materially
weaker trust bar than Core, stated as such rather than glossed over (brief §40).

## 6. Improvement — formal definition

For an exact-input swap of `amountIn` of `tokenIn` for `tokenOut`, within the current tick (§3 guarantees this):

```
ammAmountOut(amountIn) = single-tick constant-liquidity quote from
                          StateLibrary.getSlot0 + getLiquidity at the
                          moment of comparison, MINUS the pool's own swap fee
                          (so the comparison is fee-inclusive on both sides)

Improvement = venueRealizedAmountOut - ammAmountOut(amountIn)
```

Both sides are **realized-or-realizable, fee-inclusive, same-input, same-pair** — satisfying §7's requirement to not use a vague "price improvement." `venueRealizedAmountOut` is:
- Core/mock path: the mock adapter's actual token transfer, read post-transfer.
- CoW Leg: the receiver's actual received balance, read post-transfer, net of whatever CoW/solver fee already reduced it — i.e., it is already net of venue fees by construction, no separate fee subtraction needed.

**Negative or zero Improvement → no payout, full stop.** This is enforced as a `require`/early-return in code, not a policy note — §7, §15, §32's invariant "no payout without verified improvement" is structural, not advisory.

## 7. LP recapture split

```
LPShare = min(Improvement, MAX_IMPROVEMENT_BASIS) × LP_RECAPTURE_RATE_BPS / 10_000
TraderOrVenueShare = Improvement - LPShare
```

`LP_RECAPTURE_RATE_BPS` is a deployment-time constant (documented, not hidden). `MAX_IMPROVEMENT_BASIS` caps the donation basis to prevent a stale/manipulated reference price from producing an outsized claimed improvement — belt-and-suspenders on top of §3's tick-bound eligibility, which already makes manipulation of the reference price require moving the pool's actual on-chain tick, at real cost.

Rounding: both `LPShare` and the two-token split (`share0`/`share1` for `donate`) round **down**, dust remains with the trader/venue side — the mechanism never rounds in its own favor at the LP's expense, and never fabricates a fractional token unit.

## 8. Trust boundaries (§11)

| Trusted | Never trusted |
|---|---|
| v4-core's own accounting (`donate`, flash accounting, `StateLibrary` reads) | Any caller-supplied "amountOut" in `hookData` or CoW `appData` |
| Realized token balances observed *after* a transfer completes | A venue's/solver's self-reported fill |
| CoW's `HooksTrampoline` gas-bounding of the post-hook (CoW's own trust boundary, not re-verified from scratch) | The trader's stated intent ("this is benign flow") — never inferred, per §21 |
| The pool's own live tick/liquidity at comparison time | A cached/stale price from an earlier block |

## 9. Invariants (tested in Phase 5)

```
INV1: LPShare <= Improvement, always.
INV2: Improvement <= 0  ⇒  LPShare == 0  and no donate() call occurs.
INV3: No donate() call size is derived from anything but a post-transfer realized balance.
INV4: AMM fallback path never reverts due to venue/adapter/receiver failure —
      a failing venue leg degrades to plain AMM execution, never to a stuck trade.
INV5: donate() amounts never exceed the receiver/hook's own realized token balance
      at call time (no donation can be funded by anything but Improvement actually held).
INV6: Eligibility bound (§3) guarantees the AMM reference price is exact, not approximate,
      for every trade the mechanism actually prices.
```

Where each is enforced in the suite:

| Invariant | Enforcing tests |
|---|---|
| INV1 | `test/unit/ImprovementLib.t.sol::testFuzz_INV1_*`; `test/invariant/HomecomingHook.invariant.t.sol::invariant_lpDonationsNeverExceedRealizedImprovement` |
| INV2 | `ImprovementLib.t.sol::testFuzz_INV2_*`; `CowRecaptureReceiver.t.sol::test_skip_noImprovement_*` |
| INV3 | `HomecomingHook.t.sol` recapture tests (split asserted against the *logged* realized numbers) + `invariant_routedImpliesImprovement` |
| INV4 | `test/invariant/HomecomingHook.invariant.t.sol::invariant_swapsNeverRevert` + every `HomecomingHook.t.sol::test_fallsBack_*` |
| INV5 | `invariant_hookNeverRetainsTokens`, `CowRecaptureReceiverInvariant::invariant_receiverNeverRetainsTokens`, `invariant_donatedNeverExceedsPulled` |
| INV6 | `test/unit/ReferencePriceLib.t.sol` boundary regressions + `testFuzz_neverPricesBeyondTheCurrentCell` |

Additional CoW-leg invariants (not in the original list, added with the leg): the recapture pull
is always bounded by the named trader's own allowance, and an address that never approves the
receiver is never debited — `CowRecaptureReceiver.invariant.t.sol::invariant_bystanderNeverDebited`,
`CowRecaptureReceiver.t.sol::testFuzz_neverExceedsAllowance`.

## 10. Case analysis (§41)

| Case | Result |
|---|---|
| Venue/CoW worse than AMM | Improvement ≤ 0 → no payout, trader/receiver keeps the (worse) fill only if it was already executed off-chain (CoW Leg — the trader already agreed to that order); Core path never even reaches this because Core never routes real flow anywhere but the AMM |
| Venue equal to AMM | Improvement = 0 → no payout (not "AMM or venue by policy" — CoW Leg execution already happened off-chain by the time this is evaluated; Core has no real venue to choose) |
| Venue slightly / significantly better | Improvement > 0 → LP recapture proportional to Improvement, capped per §7 |
| Quote exists, settlement fails | CoW: order simply doesn't settle (no partial state) — solvers only submit settleable batches. Core/mock: `afterSwap` catches adapter failure, AMM result (already executed) stands, no recapture |
| Malicious/inflated venue output claim | Rejected — §6 never reads a claimed number, only post-transfer realized balance |

## 11. What this mechanism does **not** claim

Per §40: it does not claim guaranteed better execution, that all Unichain flow is benign, that private venues eliminate MEV, that "LPs" broadly (vs. in-range LPs at donation time) receive all improvement, or that the CoW leg's post-hook pattern is trustless beyond the trust boundaries listed in §8. It does not claim the Core deployment routes to a real venue — it explicitly does not, and says so.
