# UHI10 Hackathon · Project Brief

# Homecoming

**Bring the orderflow — and its value — home to the pool.**

A Uniswap v4 hook that routes benign flow to a real private venue (CoW Protocol / Flashbots Protect) for sandwich-free execution, with AMM fallback, and splits the realized price improvement back to the pool's LPs.

| Field | Detail |
|---|---|
| Track | UHI10 — Sustainable Liquidity & MEV Protection |
| Hook category | Hybrid routing with LP-facing recapture |
| Core primitive | On-chain routing to a real private venue + price-improvement split to LPs |
| Chain | Unichain (mainnet target); Unichain Sepolia (hackathon deploy) (contingent on venue testnet endpoints — see Feasibility) |
| Root cause attacked | Benign flow and its value are exported off the AMM to fillers/wallets |
| One-sentence pitch | Route benign flow to a real private venue and pay the improvement back to LPs. |

## Overview

Private orderflow systems — CoW Protocol, Flashbots Protect, intent and RFQ auctions — protect swappers by taking their orders out of the public mempool. But they do it beside Uniswap, not inside it: the benign, uninformed flow they capture is exactly the flow LPs want, and the value they recapture is returned to swappers, wallets, and fillers, not to the pool's LPs. The result is an adverse-selection pump: the public AMM is left facing a more toxic residual flow while the good flow and its value leave.

Homecoming brings that flow home. It is a Uniswap v4 hook that routes eligible benign flow to a real private venue for sandwich-free execution, falls back to the AMM when no better fill exists, and splits the realized price improvement back to the pool's LPs. It is the theme's fifth open problem answered head-on — and it lands the deck's single strongest differentiation lever: a genuine partner integration that none of 660 prior submissions has done.

## Problem Statement

The theme's fifth open problem states it plainly: private orderflow systems sit off to the side of Uniswap. Concretely:

- **Flow is exported.** Intent and RFQ systems preferentially capture uninformed retail flow — the profitable flow — because that is what fillers want, exactly as payment-for-order-flow does in traditional finance.
- **Value is mis-routed.** The recaptured improvement goes to the swapper, wallet, or filler; the pool's LPs, who would have earned the spread, get nothing.
- **Nobody integrates the real thing.** Seventeen prior submissions faked CoW-style matching; none integrated the real CoW Protocol or Flashbots. A genuine integration is close to guaranteed differentiation.

## Solution

Homecoming makes the pool the router and the beneficiary rather than the liquidity of last resort behind someone else's auction.

- **Route:** in `beforeSwap`, eligible benign flow is offered to a real private venue for sandwich-free settlement.
- **Fallback:** if the venue cannot beat the pool, the swap executes normally on the AMM — no worse than today.
- **Split:** the realized price improvement is split, with a share donated back to the pool's LPs — turning exported value into LP revenue.

## How It Works

- **Eligibility:** classify flow (size, path) to decide whether the private venue could improve on the pool.
- **Routing:** offer eligible flow to the venue's on-chain settlement path via `hookData` / an integration contract.
- **Compare & fall back:** take the better of venue fill and AMM fill; AMM fallback guarantees a floor.
- **Recapture split:** donate the LP share of the improvement to the pool via flash accounting.

## Architecture

| Component | Design |
|---|---|
| Hook callbacks | `beforeSwap` (eligibility + route decision), `afterSwap` (improvement split + LP donate) |
| Integration surface | Real CoW Protocol / Flashbots Protect settlement path via integration contract + `hookData` |
| Fallback | Native v4 AMM execution when the venue cannot beat the pool |
| Recapture | Price-improvement split donated to LPs through flash accounting |
| Trust boundary | Venue is external; hook verifies realized fill on-chain before crediting the split |

## Impact

- **For LPs:** improvement that today leaks to fillers and wallets is redirected into LP revenue — benign flow becomes an asset again.
- **For traders:** sandwich-free execution and price improvement, with an AMM floor — strictly better than routing to the naked pool.
- **For Uniswap / DeFi:** the first hook that composes a real private venue with the AMM and returns the value to LPs — orderflow reunification rather than fragmentation.

## Why It Matters

Homecoming stops the adverse-selection pump. Instead of accepting that benign flow and its value leave for private venues, it makes Uniswap the venue that captures both and pays its LPs. It is the most visibly ecosystem-aligned of the three ideas and the one most likely to draw attention from Uniswap itself, because it turns a competitive threat (private orderflow) into an LP revenue stream inside the protocol.

## Novelty & Differentiation

| Prior art | How Homecoming differs |
|---|---|
| CoWSwap-style hooks (UHI2, +17 attempts) | Simulated matching only; Homecoming integrates the real venue and splits improvement to LPs |
| UniswapX / intent systems | Route value to fillers/swappers off the AMM; Homecoming returns value to LPs in the pool |
| Tidehook (segmentation) | Segments internally; Homecoming composes an external real venue with AMM fallback |

## Feasibility & Technical Reality

**Critical unknown — verify first:** whether CoW Protocol / Flashbots Protect expose a Unichain Sepolia settlement endpoint the hook can integrate on testnet. The entire build hinges on this; if unavailable, the demo is partial and the gating Functionality score suffers.

- **Synchronous in-call:** swap params, pool price; venue settlement is via integration contract / `hookData`, verified on-chain.
- **Architecture must degrade gracefully:** AMM fallback ensures the hook still functions if the venue leg is unavailable, protecting the demo floor.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| No venue testnet endpoint (build-breaking) | Verify on day 1; design AMM-fallback core that demos without the venue leg if needed |
| Integration complexity for a solo dev | Scope to one venue, one pair, one flow class; time-box the integration spike |
| Improvement mis-attribution | Verify realized fill on-chain before crediting the LP split |
| Adverse selection if only benign flow routes out | Split shares improvement with the pool so LPs are compensated for what remains |

## Demo / Wow Moment

Side-by-side, the same swap: on a naked AMM it is sandwiched; through Homecoming it is routed to a real private venue, improved, and the LP receives a live donation of the improvement split. Differentiation: "the first hook to route to a real private venue and pay the price improvement back to LPs."

## Rubric Scorecard

| Criterion (weight) | Score | Rationale |
|---|---|---|
| Original Idea (30%) | 5 / 5 | First real-venue integration returning value to LPs; unattempted in 660 submissions |
| Unique Execution (25%) | 5 / 5 | Genuine external integration + AMM fallback + on-chain improvement split |
| Impact (20%) | 5 / 5 | Stops the adverse-selection pump; ecosystem-aligned |
| Functionality (15%) | 2 / 5 | Gated by venue testnet availability — boom-or-bust; verify before committing |
| Presentation (10%) | 5 / 5 | Strong side-by-side contrast; real partner name recognition |
