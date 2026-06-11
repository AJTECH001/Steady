# Steady

**Set your crypto savings on autopilot.**

Steady is a cross-chain automated savings protocol. Users create recurring savings plans — _"buy $50 of ETH every week"_ — and execution runs itself: a [Uniswap v4](https://docs.uniswap.org/contracts/v4/overview) dynamic-fee hook makes savers' swaps fee-free, and the [Reactive Network](https://dev.reactive.network/) provides the on-chain automation that fires each purchase when it's due — no off-chain keeper, no manual transactions.

<p align="center">
  <img alt="Solidity" src="https://img.shields.io/badge/Solidity-0.8.30-363636?logo=solidity">
  <img alt="Foundry" src="https://img.shields.io/badge/Built%20with-Foundry-FF6B35">
  <img alt="Uniswap v4" src="https://img.shields.io/badge/Uniswap-v4%20Hook-FF007A">
  <img alt="Reactive" src="https://img.shields.io/badge/Reactive-Network-00D395">
  <img alt="Tests" src="https://img.shields.io/badge/tests-64%20passing-brightgreen">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

> [!WARNING]
> **Unaudited software.** These contracts have not been audited. Do not use with real funds.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Partner Integrations](#partner-integrations)
5. [The Hook: `SteadyHook`](#the-hook-steadyhook)
6. [Contracts](#contracts)
7. [Repository Structure](#repository-structure)
8. [Getting Started](#getting-started)
9. [Testing](#testing)
10. [Deployment](#deployment)
11. [Security Model](#security-model)
12. [Acknowledgements & Dependencies](#acknowledgements--dependencies)
13. [License](#license)

---

## The Problem

Dollar-cost averaging (DCA) is the single most reliable retail savings strategy, but on-chain it is painful:

- **It requires discipline or a trusted bot.** You either remember to swap every week, or you hand a centralized keeper an allowance and hope.
- **Keepers are off-chain and opaque.** Most "automated" DeFi savings tools rely on a server that can fail, censor, or disappear.
- **Savers pay full swap fees** on every recurring purchase, eroding returns over time.

**Steady** removes all three. Plans live on-chain, execution is triggered trustlessly by the Reactive Network, and a Uniswap v4 hook waives the swap fee for savings executions.

---

## How It Works

```
1. createPlan(tokenIn, tokenOut, amount, interval, executions)   ← user defines a plan
2. deposit(planId, amount)                                        ← user funds the vault
3. poke(planId)        (permissionless, when due)                ← emits PlanDue
        │
        ▼  Reactive Network is subscribed to PlanDue
4. ReactiveSteady.react(log)  →  requestCallbackV_1_0(...)        ← on-chain automation
        │
        ▼  Reactive callback proxy delivers the callback
5. SteadyExecutor.executePlan(sender, planId)                     ← verified callback only
        ├─ registry.advanceSchedule(planId)   (replay-safe)
        ├─ vault.debit(planId, amount)        (pull funds)
        └─ poolManager.unlock → swap → settle → take             ← real Uniswap v4 swap
                                                                    (fee-free via SteadyHook)
6. tokenOut delivered to the saver; schedule advanced.
```

The full loop is proven end-to-end in [`test/crosschain/SteadyCrossChain.t.sol`](test/crosschain/SteadyCrossChain.t.sol).

---

## Architecture

Steady is **trigger-only cross-chain**: each plan's funds and pool stay native on one chain (the destination), while `ReactiveSteady` runs on the Reactive Network and acts as the automation glue.

```
┌──────────────────────────────────────────────┐      ┌──────────────────────────────┐
│       DESTINATION CHAIN (Unichain Sepolia)     │      │   REACTIVE NETWORK (Lasna)   │
│                                                │      │                              │
│  user ─createPlan/deposit─▶ SteadyPlanRegistry │      │   ReactiveSteady             │
│                            + SteadyVault       │      │   - subscribes to PlanDue    │
│                                  │ poke        │      │   - react() → requestCallback│
│                          emit PlanDue ─────────┼──────┼──▶ (origin event watch)      │
│                                                │      │         │                    │
│   SteadyExecutor ◀───────── callback ──────────┼──────┼─────────┘ (callback proxy)   │
│      │  unlock / swap / settle / take          │      │                              │
│      ▼                                          │      └──────────────────────────────┘
│   Uniswap v4 PoolManager  +  SteadyHook        │
│      (dynamic-fee pool; executions fee-free)   │
└──────────────────────────────────────────────┘
```

---

## Partner Integrations

> This section maps each partner technology to exactly where it lives in the code.

### Uniswap v4 (Hook + PoolManager)

| Integration | File | Where |
|---|---|---|
| **Dynamic-fee hook** (`afterInitialize` + `beforeSwap`) | [`src/execution/SteadyHook.sol`](src/execution/SteadyHook.sol) | extends `BaseOverrideFee` (L23); fee policy in `_getFee` (L71) |
| **Real v4 swap** (`unlock`/`swap`/`settle`/`take`) | [`src/execution/SteadyExecutor.sol`](src/execution/SteadyExecutor.sol) | `poolManager.unlock` (L122), `swap` (L147), `settle` (L167), `take` (L171) |
| **PoolManager addresses** | [`script/deploy/01_DeploySteady.s.sol`](script/deploy/01_DeploySteady.s.sol) | via `hookmate` `AddressConstants` by chain id |

### Reactive Network (cross-chain automation)

| Integration | File | Where |
|---|---|---|
| **Reactive contract** (`AbstractReactive`, `subscribe`, `react`, `requestCallbackV_1_0`) | [`src/reactive/ReactiveSteady.sol`](src/reactive/ReactiveSteady.sol) | subscribe (L56), `react` (L76), `requestCallbackV_1_0` (L83) |
| **Destination callback receiver** (`AbstractCallback`, dual auth) | [`src/execution/SteadyExecutor.sol`](src/execution/SteadyExecutor.sol) | `AbstractCallback` (L38/L81), `onlyServiceProvider` + `onlyReactive` (L100–101) |
| **Callback-proxy addresses** | [`script/config/ChainConfig.sol`](script/config/ChainConfig.sol) | verified per-chain proxies |

All Reactive APIs are verified against `Reactive-Network/reactive-lib-omni @ v0.1.0` (vendored in `lib/`).

---

## The Hook: `SteadyHook`

`SteadyHook` is a **Uniswap v4 dynamic-fee hook** built on OpenZeppelin's audited [`BaseOverrideFee`](https://github.com/OpenZeppelin/uniswap-hooks).

**Policy:** swaps initiated by the `SteadyExecutor` (i.e. recurring savings executions) are charged `steadyFee` (0% — fee-free DCA), while all other swappers pay `defaultFee` (0.30%).

| Property | Value |
|---|---|
| Hook permissions | `afterInitialize`, `beforeSwap` |
| Pool requirement | initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG` |
| Fee override | `beforeSwap` returns `fee \| OVERRIDE_FEE_FLAG` |
| Auth | owner sets the executor + fees |

The fee waiver is proven with real swaps in [`test/integration/SteadyHook.t.sol`](test/integration/SteadyHook.t.sol) (`test_steadyExecutionGetsFeeWaiver`).

---

## Contracts

| Contract | Responsibility |
|---|---|
| [`SteadyPlanRegistry`](src/core/SteadyPlanRegistry.sol) | Plan lifecycle (create/pause/resume/cancel), schedule math, `poke` trigger, executor-gated `advanceSchedule` |
| [`SteadyVault`](src/core/SteadyVault.sol) | Per-plan custody of the funding token; deposit/withdraw/executor-gated `debit` |
| [`SteadyExecutor`](src/execution/SteadyExecutor.sol) | Verified Reactive callback → V4 swap → deliver output; replay & slippage protection |
| [`SteadyHook`](src/execution/SteadyHook.sol) | Dynamic-fee hook making savings executions fee-free |
| [`ReactiveSteady`](src/reactive/ReactiveSteady.sol) | Reactive Network contract: watches `PlanDue`, posts cross-chain callbacks |

Supporting: [`ScheduleLib`](src/libraries/ScheduleLib.sol) (due/next-due math), [`ChainConfig`](script/config/ChainConfig.sol) (per-chain constants).

---

## Repository Structure

```
src/
├── core/        SteadyPlanRegistry.sol   SteadyVault.sol
├── execution/   SteadyExecutor.sol       SteadyHook.sol
├── reactive/    ReactiveSteady.sol
├── interfaces/  ISteadyPlanRegistry/Vault/Executor.sol
└── libraries/   ScheduleLib.sol
test/
├── unit/        per-contract + fuzz
├── integration/ executor + hook against a real local PoolManager
└── crosschain/  full poke → react → callback → swap loop
script/
├── config/      ChainConfig.sol
└── deploy/      01_DeploySteady → 06_Poke
docs/            DEPLOY.md (runbook)
```

---

## Getting Started

**Prerequisites:** [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/AJTECH001/Steady.git
cd Steady
git submodule update --init --recursive
forge build
```

---

## Testing

```bash
forge test            # 64 tests
forge test -vvv       # with traces
forge coverage        # coverage report
```

Coverage spans unit + fuzz (schedule math, vault accounting), integration against a **real local Uniswap v4 PoolManager**, and a full cross-chain simulation of the automation loop.

---

## Deployment

Steady deploys across **two networks**: a destination chain (Unichain Sepolia) for the savings contracts + pool, and the Reactive Network (Lasna) for `ReactiveSteady`.

> Arbitrum Sepolia is **not** supported by Reactive Network. Use Unichain Sepolia, Base Sepolia, or Ethereum Sepolia.

```bash
cp .env.example .env      # add PRIVATE_KEY (0x-prefixed) + RPCs
make deploy-dest          # 1. destination: tokens, core, hook, executor, pool, liquidity
make deploy-reactive      # 2. reactive:    ReactiveSteady
make wire-dest            # 3. executor → reactive sender
make wire-reactive        # 4. reactive  → executor
make demo                 # 5. create + fund a plan
make poke                 # 6. trigger execution
```

Full step-by-step runbook: [`docs/DEPLOY.md`](docs/DEPLOY.md).

### Deployed Addresses (Unichain Sepolia / Reactive Lasna)

| Contract | Network | Address |
|---|---|---|
| SteadyPlanRegistry | Unichain Sepolia | `<fill after deploy>` |
| SteadyVault | Unichain Sepolia | `<fill after deploy>` |
| SteadyHook | Unichain Sepolia | `<fill after deploy>` |
| SteadyExecutor | Unichain Sepolia | `<fill after deploy>` |
| ReactiveSteady | Reactive Lasna | `<fill after deploy>` |

---

## Security Model

- **Reentrancy:** `ReentrancyGuard` on vault deposit/withdraw/debit and executor `executePlan`; strict checks-effects-interactions.
- **Cross-chain auth (dual):** `executePlan` requires `msg.sender == Reactive callback proxy` **and** the proxy-injected `sender == ReactiveSteady`. Neither alone is sufficient.
- **Replay protection:** `advanceSchedule` reverts unless the plan's window has elapsed; schedule monotonicity prevents double-execution within a period.
- **Schedule safety:** rescheduling is anchored to `now + interval`, preventing a "catch-up burst" that could drain a plan if execution is delayed.
- **Slippage:** per-plan opt-in `minAmountOut` guard on every swap.
- **Access control:** owner-gated admin; executor-gated state mutations; hook callbacks restricted to the PoolManager.

---

## Acknowledgements & Dependencies

Steady's own contracts live in [`src/`](src/). It builds on these audited/established libraries (vendored in `lib/`):

- [Uniswap v4-core / v4-periphery](https://github.com/Uniswap/v4-core) — PoolManager, hook interfaces, `HookMiner`.
- [OpenZeppelin `uniswap-hooks`](https://github.com/OpenZeppelin/uniswap-hooks) — `BaseHook`, `BaseOverrideFee` (the base for `SteadyHook`).
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — `Ownable`, `SafeERC20`, `ReentrancyGuard`.
- [`Reactive-Network/reactive-lib-omni`](https://github.com/Reactive-Network) `@ v0.1.0` — `AbstractReactive`, `AbstractCallback`.
- [`hookmate`](https://github.com/akshatmittal/hookmate) — canonical V4 address constants.

Bootstrapped from the OpenZeppelin Uniswap v4 hook template. All Steady-specific logic was written during the Hookathon period.

---

## License

[MIT](LICENSE)
