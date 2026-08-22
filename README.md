# Homecoming

**Bring the orderflow — and its value — home to the pool.**

A Uniswap v4 protocol that identifies eligible benign flow, attempts to capture value from private
execution, and returns a share of any realized improvement to the pool's LPs — with plain AMM
execution as the unconditional floor. Built as two honest, separately-labeled pieces after
discovering the original single-hook brief could not be built as specified. Read
[FEASIBILITY.md](./FEASIBILITY.md) first — it's the reason the architecture below looks the way it
does, not an afterthought.

---

## 1. The problem

Private orderflow systems — CoW Protocol, Flashbots Protect, intent and RFQ auctions — protect
swappers by taking their orders out of the public mempool. They do this *beside* Uniswap, not
inside it: the benign, uninformed flow they capture is exactly the flow LPs want, and the value
they recapture goes to swappers, wallets, and fillers — never to the pool's LPs. The public AMM is
left facing more adverse residual flow while the good flow, and its value, leaves.

## 2. Why this creates an LP problem specifically

LPs earn from spread and fees on the flow that actually trades against their liquidity. Flow that
gets siphoned off to a private venue before it ever reaches a pool doesn't just miss out on paying
that spread — it changes the *composition* of what's left. Uninformed flow is what LPs want to
trade against; informed/adverse flow is what hurts them. If private venues systematically pull the
former away, LPs are left holding more of the latter, for less total volume. That's the adverse-
selection dynamic Homecoming is aimed at.

## 3. What was actually built, and why it's two pieces

The original brief proposed a single v4 hook: `beforeSwap` routes eligible flow to a real private
venue (CoW Protocol or Flashbots Protect), compares the fill to the AMM, and `afterSwap` splits the
improvement to LPs. **This is not implementable as specified**, for reasons discovered in Phase 1
and documented exhaustively in [FEASIBILITY.md](./FEASIBILITY.md):

- **Flashbots Protect is not a settlement venue.** It's a private-RPC transaction-submission
  service. There is no quote, no fill, no contract for a hook to call — "route this swap to
  Flashbots Protect" is not an operation that exists at the point a v4 hook executes.
- **CoW Protocol's settlement is asynchronous and solver-driven** — a signed order goes through an
  off-chain batch auction, and the *winning solver* submits the settlement transaction, at a time
  and in a transaction nobody else controls. A `beforeSwap`/`afterSwap` pair executing atomically
  inside one transaction cannot "call CoW and wait for a fill."
- **CoW has no canonical deployment on Unichain at all** — only a fork ("Ophis") does, and
  integrating with a fork while calling it "the real CoW Protocol" would itself be exactly the kind
  of fake integration this project set out to avoid.

Rather than fake it, the build split into two honestly-scoped, separately-deployed pieces:

| | **Homecoming Core** | **Homecoming CoW Leg** |
|---|---|---|
| Chain | Unichain Sepolia (the brief's target) | Ethereum Sepolia (the only chain with both real CoW *and* v4-core) |
| What it is | A real v4 hook: eligibility, exact AMM reference pricing, LP recapture via `donate()`, AMM fallback | A real CoW Protocol integration: a post-hook receiver that pulls a trader-approved LP share after a genuine CoW settlement |
| Real venue on this chain? | **No.** `venueAdapter` defaults to `address(0)`; every real swap takes the plain AMM path, identical to a hookless pool | **Yes.** Canonical `GPv2Settlement`, canonical CoW orderbook API, real off-chain solver competition |
| What proves it works | 4 integration tests against the **real** `PoolManager`, including the mock-adapter-driven recapture path | 3 integration tests proving the receiver only ever pulls a bounded, trader-approved amount |

This is not a downgrade dressed up as a feature — it's the direct, literal implementation of the
brief's own §38: *"if neither is viable... build Homecoming Core with a clean venue-adapter
architecture and an honest testnet demonstration, and document the limitation."*

## 4. Homecoming Core — routing architecture

```
beforeSwap
  │
  ├─ exact-output swap, native currency, or no adapter configured → plain AMM (ZERO_DELTA)
  │
  └─ eligible (size ≥ min, stays within the pool's current tick-spacing cell) AND adapter available
       │
       └─ try { attemptVenueRoute(...) }     // self-call, isolated in its own frame
            │  take() input from PoolManager → hand to adapter → measure REALIZED balance delta
            │  (never trust the adapter's claimed amount)
            │
            ├─ adapter fails, or realized fill ≤ AMM reference → revert
            │      caught by _beforeSwap's catch{} → falls through to plain AMM,
            │      exactly as if no adapter attempt had ever been made
            │
            └─ realized fill > AMM reference → commit:
                   split Improvement → settle() trader's share into PoolManager
                                     → donate() LP share to in-range LPs
                   return a BeforeSwapDelta that fully substitutes for the AMM swap
```

No real synchronous venue exists to configure on Unichain Sepolia (see §3), so in production this
branch never fires for real traffic — but it is real, tested code, not a stub: `MockVenueAdapter`
(explicitly labeled, test/demo-only — see its own NatSpec) exercises the entire path end-to-end
against the actual `PoolManager`, including a genuine `donate()` call and exact value reconciliation.

**Why not just NoOp the AMM swap generically for any venue?** Because that requires a synchronous
settlement counterparty — see [ARCHITECTURE_VALIDATION.md](./ARCHITECTURE_VALIDATION.md) §5 for why
neither CoW nor Flashbots Protect can ever be that counterparty, on any chain.

## 5. Homecoming CoW Leg — the real integration

Control flows the opposite direction from what the brief originally imagined: a CoW settlement
calls *into* the pool, not a pool hook calling *into* CoW.

```
Trader signs a CoW order, receiver = trader's own wallet (paid normally, directly — no shared custody)
   appData → post-hook = CowRecaptureReceiver.recapture(key, zeroForOne, trader, amountInClaimed, venueAmountOutClaimed)
        ↓
Off-chain solver competition (real CoW orderbook, api.cow.fi/sepolia)
        ↓
Winning solver's GPv2Settlement.settle() tx:
   trader is paid their real CoW-settled output directly
   → post-hook fires atomically via HooksTrampoline:
        reads live pool state, computes the AMM reference for amountInClaimed
        computes Improvement, LP share
        pulls ONLY the LP share, via transferFrom bounded by the trader's own pre-approved allowance
        donate()s it to the pool
```

A first design had the receiver custody trade proceeds and forward a caller-chosen share to a
caller-chosen recipient. Building it surfaced a real vulnerability — any caller could name
*themselves* as recipient and drain whatever balance was sitting there. See
[SECURITY.md](./SECURITY.md) §1.2 for the finding and the redesign. The shipped version never
custodies funds and never pays out to a caller-chosen address — see `CowRecaptureReceiver.sol`'s
NatSpec for the full trust-model writeup, including the honest limitation that (unlike Core) this
leg cannot independently verify a CoW order's real amounts and is therefore consent-based.

## 6. Improvement — the formal definition

For an exact-input swap of `amountIn`, within the pool's current tick-spacing cell:

```
ammAmountOut(amountIn) = exact, fee-inclusive single-tick quote via StateLibrary + v4-core's own
                          SwapMath.computeSwapStep — not a reimplementation, not an approximation

Improvement = venueRealizedAmountOut − ammAmountOut(amountIn)     (never negative; ≤0 ⇒ 0, no payout)

LPShare = min(Improvement, amountIn × maxImprovementBpsOfAmountIn) × lpRecaptureBps / 10_000
```

Both sides of the comparison are real, fee-inclusive, same-input, same-pair numbers — see
[MECHANISM.md](./MECHANISM.md) §6 for the full derivation and why a naive "just call the periphery
Quoter" approach doesn't work on-chain (its own authors document it as off-chain-only).

## 7. LP recapture — what `donate()` actually does

`PoolManager.donate()` pays **only currently in-range liquidity at `slot0.tick`**, at the moment of
the call — not "the pool's LPs" broadly, and it is documented by Uniswap itself as JIT-frontrunnable
(add liquidity right before a donation, remove it right after). Homecoming states this precisely
rather than the looser "LPs get paid" — see [ARCHITECTURE_VALIDATION.md](./ARCHITECTURE_VALIDATION.md)
§4 and [SECURITY.md](./SECURITY.md) §4.

## 8. Security

Full adversarial review in [SECURITY.md](./SECURITY.md), including two findings caught while
*building* this (not found after the fact): a tick-boundary edge case in the reference-pricing math
that silently disabled the entire recapture path for any freshly-initialized pool, and the CoW-leg
custody vulnerability described above. Both are fixed in the shipped code, with regression tests.

## 9. Limitations — stated plainly

- No real private venue is reachable from Unichain Sepolia. Every real Core-leg swap executes as
  plain AMM. This is the honest consequence of FEASIBILITY.md's findings, not a bug.
- The CoW leg's Improvement inputs are trader-self-reported; it cannot independently verify a CoW
  order's real amounts the way Core verifies real `SwapParams`. Bounded to "a dishonest trader
  under-contributes," never to fund extraction — see SECURITY.md §1.2.
- `donate()`'s JIT-frontrun exposure is inherited, not solved.
- Native-currency pools, fee-on-transfer/rebasing tokens, and exact-output swaps are explicitly out
  of scope.
- `governance` is a single address with no timelock — fine for a testnet build, not for production.
- No external audit. Treat this as hackathon-stage code.

## 10. What this does **not** claim

Homecoming does not claim guaranteed better execution, that all flow is benign, that private venues
eliminate MEV, that all LPs (vs. in-range LPs at donation time) receive improvement, or that the
Core deployment routes to a real venue on Unichain — it explicitly does not, and says so throughout.

## 11. Repository layout

```
src/
  HomecomingHook.sol                        Core leg — the v4 hook (Unichain Sepolia)
  integrations/
    IPrivateVenueAdapter.sol                Interface a real synchronous venue would need
    MockVenueAdapter.sol                    Test/demo-only — clearly labeled, not a real venue
    cow/
      CowRecaptureReceiver.sol              CoW leg — the real integration (Ethereum Sepolia)
      vendor/HooksTrampoline.sol            Vendored verbatim from cowprotocol/hooks-trampoline
  libraries/
    HomecomingTypes.sol                     Shared config/result structs
    EligibilityLib.sol                      Objective routing-eligibility policy
    ReferencePriceLib.sol                   Exact single-tick AMM reference pricing
    ImprovementLib.sol                      Improvement/LP-split math (pure, fuzz-tested)
    CurrencySettleLib.sol                   Production copy of v4-core's settle/take pattern
script/
  DeployHomecomingCore.s.sol                CREATE2-mined hook deployment (Unichain Sepolia)
  DeployCowLeg.s.sol                        Receiver + HooksTrampoline deployment (Ethereum Sepolia)
test/
  unit/                                     Pure-math unit + fuzz tests (no PoolManager needed)
  integration/                              Run against the REAL v4-core PoolManager
FEASIBILITY.md            Phase 1 — the venue feasibility investigation that gates everything else
ARCHITECTURE_VALIDATION.md Phase 2 — verified v4-core execution semantics, sourced from real code
MECHANISM.md               Phase 3 — the formal mechanism design
SECURITY.md                Phase 7 — adversarial review and findings
```

## 12. Testing

```
forge build
forge test -vv
```

18 tests, 4 suites, all passing as of this writing: pure-math unit tests with 256-run fuzz coverage
on the core Improvement/LP-split invariants, plus integration tests that deploy the **real**
`PoolManager` (via v4-core's own `Deployers` test harness) and exercise the full swap/donate/settle
sequence end to end — not a simplified mock of PoolManager. See [MECHANISM.md](./MECHANISM.md) §9
for the invariants under test and [SECURITY.md](./SECURITY.md) §1.1 for a case where the integration
suite caught a real bug the unit tests alone would have missed.

## 13. Deployment

Both scripts are written and compile; they have not yet been broadcast to either testnet (that
requires a funded deployer key and RPC access this build environment doesn't have). To deploy:

```
# Homecoming Core → Unichain Sepolia (chain id 1301)
forge script script/DeployHomecomingCore.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast --verify

# Homecoming CoW Leg → Ethereum Sepolia (chain id 11155111)
forge script script/DeployCowLeg.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --broadcast --verify
```

Both scripts read the correct `PoolManager` address per-chain from `hookmate`'s `AddressConstants`
(cross-verified against Uniswap's own deployments documentation before being relied on — see
inline citations in the scripts). `DeployHomecomingCore` mines a CREATE2 salt so the deployed hook
address encodes exactly the `beforeSwap`/`beforeSwapReturnDelta` permission bits it needs.

## 14. Demo

Not yet built in this pass — see the project's task tracking for the deterministic demo flow
(plain AMM vs. mock-venue-driven recapture on Core; real CoW settlement plus receiver pull on the
CoW leg), to be built once both legs are deployed to their target testnets.
