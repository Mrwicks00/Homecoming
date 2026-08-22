# FEASIBILITY.md — Homecoming Venue Integration Feasibility

Status: **GATING FINDING — original architecture is not implementable as specified. See §16 recommendation.**

This document answers the 16 feasibility questions from the project brief before any hook code is written, per the mandated Phase 0/Phase 1 process. Claims are sourced; where a claim cannot be sourced it is marked as an assumption.

---

## Executive summary

Neither **CoW Protocol** nor **Flashbots Protect** can be synchronously — or even loosely, asynchronously-but-hook-triggered — composed with a Uniswap v4 hook on **Unichain / Unichain Sepolia** in the way the brief describes ("`beforeSwap` routes the swap to the venue, venue returns a fill, `afterSwap` splits the improvement"). The failure is not a testnet-availability inconvenience; it is architectural, for two independent reasons:

1. **CoW Protocol has no canonical deployment on Unichain at all.** The canonical `GPv2Settlement` contract is deployed on ~10 chains (Ethereum, Gnosis, Arbitrum One, Base, Polygon, Avalanche, etc.) but Unichain is not among them. A project called **Ophis** runs a bytecode-identical *fork* of `GPv2Settlement` at a non-canonical address on Unichain and Optimism — that is a different, unaudited-by-the-same-process deployment, not "the real CoW Protocol." Integrating with it and calling it "a genuine CoW Protocol integration" would itself be the kind of fake integration this project explicitly forbids. [CoW Protocol contracts](https://docs.cow.fi/cow-protocol/reference/contracts/core), [Ophis vs CoW Swap](https://ophis.fi/blog/ophis-vs-cow-swap/)
2. **Even on chains where CoW is canonical, its settlement model cannot be called synchronously from inside a swap.** CoW orders are off-chain signed intents; solvers compete off-chain (an auction that takes on the order of seconds, with no on-chain deadline a hook can block on) and the *winning solver* submits the settlement transaction — at a time and in a transaction the trader, the router, and the hook do not control. A v4 hook's `beforeSwap`/`afterSwap` execute atomically inside one transaction; there is no way to "call CoW and wait for a fill" inside that transaction. [CoW Protocol architecture](https://cowswap.mintlify.app/cow-contracts/concepts/architecture)

Flashbots Protect fails for a more basic reason: **it is not an execution or settlement venue at all.** It is a private-RPC transaction-submission service — the trader's wallet sends its transaction to `protect.flashbots.net` instead of the public mempool, and it is forwarded directly to a block builder. There is no quote, no fill, no settlement contract, and no on-chain object a hook could invoke or verify. "Route this swap to Flashbots Protect" is not an operation that exists at the point a v4 hook executes — by the time `beforeSwap` runs, the *trader's own transaction* has already been built and included via whatever RPC path the trader chose, before the hook ever sees it. A hook cannot retroactively decide to submit the enclosing transaction privately. [Flashbots Protect overview](https://docs.flashbots.net/flashbots-protect/overview)

A further, compounding finding: **Unichain already runs its own Flashbots-built MEV mitigation at the sequencer level.** Unichain uses Rollup-Boost, a TEE-based block builder built by Uniswap Labs and Flashbots, which enforces priority-fee-ordering over an encrypted mempool — i.e., classic sandwich ordering games are already substantially mitigated chain-wide, for *all* flow, not just flow a hook opts in to routing. [Rollup-Boost live on Unichain](https://blog.uniswap.org/rollup-boost-is-live-on-unichain), [Flashbots: Unichain mainnet TEE builder](https://writings.flashbots.net/unichain-mainnet). This changes the marginal value proposition Homecoming is pitched against: on Unichain, "sandwich-resistant execution" is partly already a chain-level property, not something only an off-chain private venue can provide.

**Conclusion:** the brief's central differentiator — "a genuine partner integration that none of 660 prior submissions has done," built as a synchronous hook-to-venue route — is not buildable on the stated chain without misrepresenting what is actually deployed. Continuing to build toward it would require either (a) faking the integration (forbidden), or (b) quietly using a fork and calling it the real thing (also forbidden, and identified above as the exact anti-pattern to avoid). Section 38 of the engineering brief anticipates this outcome and specifies the fallback: build **Homecoming Core** — a real, correctly-architected v4 hook with a clean venue-adapter boundary and an honest AMM-fallback/recapture mechanism — and document the limitation rather than force it. See the recommendation in §16 below for the two concrete paths this opens.

---

## Q1. Can Homecoming actually integrate with CoW?

Only partially, and not in the shape the brief assumes.

- **On Unichain: no.** No canonical CoW deployment exists there (see executive summary). A hook cannot integrate with something that isn't deployed on its chain.
- **On a chain where CoW is canonical** (Ethereum, Gnosis, Arbitrum, Base, Polygon, Avalanche, ...): CoW does expose a genuine atomic-composition primitive — **CoW Hooks**. An order's `appData` can attach a pre-interaction and/or post-interaction: an arbitrary contract call executed *atomically within the solver's settlement transaction*, before the order's funds are pulled (pre-hook) or after the batch's proceeds are credited (post-hook). [CoW Hooks docs](https://docs.cow.fi/cow-protocol/concepts/order-types/cow-hooks), [CoW Hooks reference](https://docs.cow.fi/cow-protocol/reference/core/intents/hooks)
- The direction of control is **inverted** from the brief: CoW's settlement transaction can call *into* a v4 pool (e.g., to `donate()`), but a v4 pool's swap transaction cannot call *into* CoW and get a fill back, because the fill doesn't exist yet at that point — it's produced later, off-chain, by solver competition.

So a real CoW integration is possible in principle, but as a **CoW-side post-hook that pays a v4 pool**, not as a **v4-hook-side call that routes into CoW** — and only on a chain where CoW is canonically deployed, which excludes Unichain.

## Q2. Can Homecoming actually integrate with Flashbots?

No, not as an execution venue, on any chain. Flashbots Protect is an RPC/transaction-privacy layer, not a settlement system. There is no contract to call, no fill to verify, no quote to compare against the AMM. Nothing about "routing to Flashbots Protect" is a valid operation at the point a v4 hook runs. (Unichain's own Rollup-Boost is the closest Flashbots-built thing that's actually relevant to Unichain, and it's chain infrastructure, not an integratable venue — see executive summary.)

## Q3. Which venue is technically compatible?

Neither is compatible with the brief's synchronous "hook routes → venue fills → hook compares" architecture, on any chain, because CoW settlement is fundamentally asynchronous/solver-driven and Flashbots Protect isn't a settlement venue at all. CoW is compatible with a **different, honest architecture** (CoW-side post-hook pays the pool) but only where CoW is canonically deployed.

## Q4. On which chain?

Not Unichain or Unichain Sepolia for any real CoW composition (no canonical deployment). If a real CoW integration is pursued at all, it requires a chain where CoW is canonical — e.g., Ethereum Sepolia (if CoW testnet is live there) or one of CoW's supported mainnets. This is a direct conflict with the brief's stated chain target and must be resolved by the user (see §16).

**Checked exhaustively, not just for Unichain — confirmed no other testnet works either.** The full, authoritative list of CoW's canonical `GPv2Settlement` deployments, pulled directly from `cowprotocol/contracts/deployments/`, is: `arbitrumOne, avalanche, base, bsc, goerli, mainnet, optimism, polygon, rinkeby, sepolia, xdai`. Confirmed via each network's own `.chainId` file: `base` = 8453 (Base **mainnet**; no `baseSepolia` entry exists in the repo at all) and `sepolia` = 11155111 (Ethereum Sepolia). Of every testnet CoW has ever canonically deployed to, **Ethereum Sepolia is the only one still live** (Goerli and Rinkeby are deprecated, dead Ethereum testnets). This was checked in response to a specific "what about Base Sepolia instead of Unichain?" question — the answer generalizes: no L2 testnet has a real CoW deployment, only Ethereum's. That is why the CoW leg (`CowRecaptureReceiver`) targets Ethereum Sepolia specifically, not a preference among several equally-viable options.

## Q5. Is testnet deployment possible?

The **hook itself** (AMM path, eligibility, fallback, LP-recapture accounting) can be deployed to Unichain Sepolia today — that part depends only on v4-core, which is deployed on Unichain Sepolia. [Uniswap Unichain contract addresses](https://developers.uniswap.org/docs/unichain/technical-information/contract-addresses). A **real CoW settlement path** cannot be tested on Unichain Sepolia because no canonical CoW deployment exists there to test against.

## Q6. What is the exact settlement path (if CoW is used, off-Unichain)?

Trader signs an off-chain EIP-712 order (optionally with a post-hook in `appData`) → order posted to CoW's off-chain orderbook API → solvers compete in an off-chain batch auction → winning solver calls `GPv2Settlement.settle()` in its own transaction, executing all matched orders plus any attached pre/post-interactions atomically → post-hook (if present) fires as part of that same transaction, e.g. calling a recapture contract that donates into a v4 pool. This entire path is a **separate transaction from, and has no fixed timing relationship to, any specific swap transaction on the AMM.**

## Q7. What contracts are involved?

`GPv2Settlement` (canonical CoW settlement singleton), `GPv2VaultRelayer` (token pulls), the CoW order's hook target contract (a Homecoming-authored "recapture receiver" that calls `PoolManager.donate()`), and `PoolManager` itself. No CoW contract is involved for the pure-AMM leg.

## Q8. What information must exist before execution?

For the CoW leg: a signed order, correct `appData` hash committing to the hook calldata (per CoW's hook-trampoline pattern, since hooks are called via a `HooksTrampoline` contract, not directly by `GPv2Settlement`, to bound gas and prevent a malicious hook from reverting the whole batch — [hooks-trampoline](https://github.com/cowprotocol/hooks-trampoline)), and the recapture receiver's address/logic already deployed and audited before any order references it. For the AMM leg: nothing beyond a normal v4 swap.

## Q9. What happens synchronously during the v4 swap?

Only AMM execution: eligibility check, optional fee/delta adjustment via `BeforeSwapDelta`, the pool's own concentrated-liquidity swap math, and (if the design calls for it) a `donate()` of previously-realized, already-verified improvement from a *prior, separate* CoW settlement. Nothing about "did the venue beat the AMM for *this* swap" can be resolved synchronously, because for this swap there is no venue leg at all — venue-sourced flow, if it exists, took the CoW off-chain path entirely and never touches `beforeSwap`/`afterSwap` of an AMM swap.

## Q10. What happens asynchronously?

The entire CoW order lifecycle: signing, off-chain solver competition, and settlement. This is why, if a real CoW leg is pursued, "improvement" cannot be computed by comparing to *that specific swap's* AMM counterfactual inside a swap hook — there is no swap hook invocation for CoW-routed flow. It must instead be computed by the CoW-side post-hook itself, using pool state read at settlement time as the AMM reference, then donated in the same atomic settlement transaction.

## Q11. Can the hook enforce the route?

No. A v4 hook cannot force a trader's transaction to go to CoW instead of the pool — routing choice is made by the trader/router *before* the pool transaction exists, or is a completely separate CoW order that never touches the pool's hook at all. The hook can only decide, for swaps that do arrive at the pool, whether to apply its own logic (eligibility, fee adjustment, fallback) — it cannot reach out and pull in a competing venue's fill.

## Q12. Can the hook verify the fill?

For a same-transaction fill: not applicable, because no venue produces a same-transaction fill (see above). For a CoW post-hook design: yes — and it must. The recapture receiver, called atomically by CoW's settlement transaction, can read actual realized transfer amounts (from `GPv2Settlement`'s own accounting / the tokens the receiver contract actually holds at that instant) rather than trusting any caller-supplied number. This satisfies the brief's "single source of truth" requirement (§14) — but only in the CoW-post-hook architecture, not the original hook-routes-to-venue architecture.

## Q13. Can the hook compare venue execution against AMM execution?

Only if it independently computes the AMM counterfactual from live pool state at the moment of comparison (see MECHANISM/ARCHITECTURE_VALIDATION for the exact method — quoting via `StateLibrary`/a quoter-style calldata simulation, not a real mutating swap). This is possible in both the CoW-post-hook design (comparison happens in the receiver contract, reading pool state via `extsload`/`StateLibrary`) and is irrelevant in the pure-AMM-only design (no comparison needed, there is no other execution to compare to).

## Q14. Can LP value be returned atomically?

Yes, via `PoolManager.donate()`, which requires being inside an `unlock()` callback (flash-accounting) and donates to **currently in-range liquidity at `slot0.tick` only** — not to "the pool's LPs" broadly, and not to out-of-range LPs. [`donate()` behavior](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol), [in-range-only limitation](https://github.com/Uniswap/v4-core/issues/346). This is atomic within whichever transaction calls it (a v4 swap transaction for the AMM-only design, or the CoW settlement transaction for the post-hook design) — but it is a narrower claim than "LPs get paid" and must be stated precisely (see §19 in MECHANISM.md). `donate()` is also documented as front-runnable by JIT liquidity added immediately before the call — a real attack surface to address in SECURITY.md.

## Q15. What assumptions are trusted?

- v4-core and its `donate()`/flash-accounting semantics behave as documented and audited.
- If a CoW post-hook path is built: CoW's `HooksTrampoline` correctly gas-bounds and isolates hook execution from the rest of the batch (this is CoW's trust boundary, not Homecoming's to re-verify from scratch, but it is a dependency).
- The recapture receiver contract itself is not upgradeable-by-an-attacker and is deployed once, immutably referenced by orders.
- No assumption is made that a caller-supplied "venue output" number is honest — it is never trusted; only realized balances/pool state are used.

## Q16. What cannot be guaranteed?

- That any given real-world swap is actually superior at a private venue at all (Homecoming can only react to whichever fills happen to arrive, and on Unichain, no real CoW fills can arrive).
- That "the pool's LPs" as a whole benefit — only in-range LPs at donation time benefit, and JIT liquidity can capture a disproportionate share.
- That private routing exists at all for Unichain-Sepolia-deployed flow, given no canonical CoW settlement is reachable there.
- Deterministic, venue-driven demo behavior on Unichain Sepolia, since there is no real venue to demo against there.

---

## Recommendation

Per §38 of the engineering brief ("if neither is viable, do not force it — build Homecoming Core with a clean venue-adapter architecture and an honest testnet demonstration, and document the limitation"), the path forward is:

**Build Homecoming Core:**
- A real, correctly-implemented v4 hook deployed to Unichain Sepolia: eligibility, deterministic AMM-reference pricing, `donate()`-based LP recapture, and a fallback path that is the *only* path exercised on Unichain (since no real venue is reachable there).
- A real `IPrivateVenueAdapter` interface shaped around the **CoW-post-hook control-flow direction that is actually real** (receiver-pattern, not router-pattern) — not a fake "call CoW synchronously" interface.
- A `MockVenueAdapter` used **only** in unit tests, explicitly and loudly labeled as a mock, per §30's requirement to never let a mock stand in for proof of integration.
- Clear documentation (this file + README + ARCHITECTURE_VALIDATION.md) that the "real private venue" claim in the original brief does not hold on Unichain, why, and what would be required to make it real (deploying the recapture-receiver + CoW post-hook pattern on a CoW-canonical chain).

This is an explicit deviation from the original brief's chain/venue claims, made because the alternative is a fabricated integration. The **decision the user needs to make** is which of two concrete follow-on paths to take — see the question that follows this document.

---

Sources:
- [CoW Protocol Core Contracts](https://docs.cow.fi/cow-protocol/reference/contracts/core)
- [Ophis vs CoW Swap: what a CoW Protocol fork changes](https://ophis.fi/blog/ophis-vs-cow-swap/)
- [CoW Protocol Architecture](https://cowswap.mintlify.app/cow-contracts/concepts/architecture)
- [Flashbots Protect Overview](https://docs.flashbots.net/flashbots-protect/overview)
- [Live on Unichain: Fair Transaction Ordering and MEV Protection (Rollup-Boost)](https://blog.uniswap.org/rollup-boost-is-live-on-unichain)
- [The First L2 TEE Block Builder is Live on Unichain Mainnet](https://writings.flashbots.net/unichain-mainnet)
- [CoW Hooks](https://docs.cow.fi/cow-protocol/concepts/order-types/cow-hooks)
- [CoW Hooks Reference (pre/post-interactions)](https://docs.cow.fi/cow-protocol/reference/core/intents/hooks)
- [cowprotocol/hooks-trampoline](https://github.com/cowprotocol/hooks-trampoline)
- [Uniswap v4 IPoolManager.sol](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol)
- [donate() in-range-only limitation, Issue #346](https://github.com/Uniswap/v4-core/issues/346)
- [BeforeSwapDelta Guide](https://docs.uniswap.org/contracts/v4/reference/core/types/beforeswapdelta-guide)
- [Custom Accounting Guide](https://docs.uniswap.org/contracts/v4/guides/custom-accounting)
- [Uniswap v4 Unichain Contract Addresses](https://developers.uniswap.org/docs/unichain/technical-information/contract-addresses)
- [Building Secure Uniswap v4 Hooks — Trail of Bits](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/)
