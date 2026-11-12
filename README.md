# Property Tokenization Protocol

[![CI](https://github.com/danushkka/property-tokenization/actions/workflows/test.yml/badge.svg)](https://github.com/danushkka/property-tokenization/actions/workflows/test.yml)

A compliance-gated, dividend-paying real-world asset (RWA) tokenization system built in Solidity with Foundry, with a React dashboard for interacting with it. Fractional ownership of a real-world property is represented as an ERC-20 token, restricted to whitelisted (KYC'd) holders, with snapshot-based dividend distribution of rental income and a timelock-protected governance layer around sensitive admin actions.

**Live links:** [Dashboard](https://property-tokenization-nu.vercel.app) · [Verified contracts on Sepolia](#live-deployment-sepolia) · [On-chain demo transactions](#live-demonstration)

The project was designed and built end-to-end: architecture, contracts, tests, deployment tooling, a TypeScript client, and a web dashboard. It started from a research conversation about asset tokenization and was developed through iterative design review and extensive testing.

---

## Table of contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Key design decisions](#key-design-decisions)
- [Contracts](#contracts)
- [Roles and permissions](#roles-and-permissions)
- [Live deployment (Sepolia)](#live-deployment-sepolia)
- [Live demonstration](#live-demonstration)
- [Dashboard](#dashboard)
- [Tech stack](#tech-stack)
- [Getting started](#getting-started)
- [Testing](#testing)
- [Security considerations](#security-considerations)
- [Known limitations and roadmap](#known-limitations-and-roadmap)
- [Project structure](#project-structure)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## Overview

Real-world asset tokenization represents ownership of an off-chain asset (here, a property) as an on-chain token. This project implements a full, working system for that:

1. **Compliance-gated ownership**: tokens can only be minted to, held by, or transferred between whitelisted (KYC'd) addresses.
2. **Primary issuance**: whitelisted buyers purchase newly minted tokens directly with a stablecoin, at a price that adjusts instantly within safe bounds, or through governance for larger moves.
3. **Custody of rental income**: a dedicated vault holds stablecoin deposits representing the property's real-world income.
4. **Proportional dividend distribution**: holders claim their share of declared dividends based on their token balance at the moment each dividend was declared, not their current balance, which prevents buy-then-claim exploitation.
5. **Governance-protected administration**: sensitive admin actions (changing the compliance validator, reassigning operational roles, large price movements) go through a 72-hour timelock with guardians able to cancel (see [Security considerations](#security-considerations) for the exact scope in the current deployment).
6. **Web dashboard**: a React app where a connected wallet can check its status, buy tokens, and claim dividends.

The full purchase → dividend declaration → dividend claim lifecycle has been executed on Sepolia with real testnet USDC (see [Live demonstration](#live-demonstration)).

---

## Architecture

```
 ┌──────────────────┐   mint    ┌───────────────────────┐  canTransfer  ┌────────────────────┐
 │ PropertyIssuance │──────────►│     PropertyToken     │──────────────►│ WhitelistValidator │
 │ (buy with USDC)  │           │  (ERC20Votes, supply  │               │  (KYC whitelist)   │
 └────────┬─────────┘           │  cap, compliance hook)│               └────────────────────┘
          │ USDC proceeds       └───────────┬───────────┘
          ▼                                 │ getPastVotes /
     [treasury]                             │ getPastTotalSupply
                                            ▼
 ┌───────────────┐   withdrawTo   ┌───────────────────────┐
 │ RevenueVault  │◄───────────────│  DividendDistributor  │
 │ (USDC income) │                │ (rounds, pull claims) │
 └───────────────┘                └───────────────────────┘
        ▲ deposit (DEPOSITOR_ROLE)

 ┌─────────────────────────────────────────────────────────┐
 │ TimelockController: 72h delay, guardian cancellation    │
 │ holds DEFAULT_ADMIN_ROLE on all five contracts above    │
 │ (see Roles and permissions)                             │
 └─────────────────────────────────────────────────────────┘
```

Off-chain, three clients talk to the same deployed contracts:

```
 Browser + MetaMask ──► dashboard/ (React + viem) ──────┐
 Terminal ───────────► client/ (viem read scripts) ─────┼──► Sepolia contracts
 Terminal ───────────► script/ (Foundry deploy + demo) ─┘
```

Each contract has one narrow responsibility:

| Contract | Responsibility |
| --- | --- |
| `WhitelistValidator` | Answers one question: can this address send or receive tokens? |
| `PropertyToken` | ERC-20 + `ERC20Votes` balances; enforces compliance on every transfer, mint, and burn through a single `_update` hook. |
| `PropertyIssuance` | Sells newly minted tokens to whitelisted buyers for stablecoin; adjustable pricing. |
| `RevenueVault` | Pure custody of stablecoin; releases funds only to the trusted `DividendDistributor`. |
| `DividendDistributor` | Tracks dividend rounds and lets holders claim their proportional, snapshot-based share. |
| `TimelockController` | OpenZeppelin timelock that delays, and allows cancellation of, governance actions. |

---

## Key design decisions

Each choice below was made to close a specific, real-world risk:

- **Compliance as a pluggable hook.** `PropertyToken` asks `WhitelistValidator`, through a minimal `IComplianceValidator` interface, whether each transfer is allowed. It does this in its `_update` override, the single choke point for every balance change (transfer, mint, burn), so no path can skip the check. Setting the validator to the zero address is rejected, since that would freeze every transfer.

- **Snapshot-based dividends via `ERC20Votes`.** A holder's eligibility for a round is fixed at the block before that round was declared, using OpenZeppelin's checkpoint mechanism. This closes an exploit where someone buys tokens right before a dividend and sells right after.

- **Auto-delegation on first receipt, and no delegation to anyone else.** `ERC20Votes` only checkpoints a holder's balance once they have delegated, which would silently exclude holders from dividends, so `PropertyToken` self-delegates each new holder on first receipt. Because dividend eligibility follows voting power, letting a holder delegate to another address would redirect their dividends, possibly to a non-whitelisted address. `delegate` therefore accepts only the caller's own address, and `delegateBySig` is disabled.

- **`Math.mulDiv` for every proportional calculation.** A plain `a * b / c` can overflow at the multiplication even when the true result fits in a `uint256`. Dividend shares and purchase costs use OpenZeppelin's full-precision `mulDiv`. Purchase cost rounds down, so a buyer can underpay by less than one smallest USDC unit per purchase; this is deliberate, negligible, and bounded by an invariant.

- **Hybrid real-time / timelocked pricing.** `PropertyIssuance.updatePrice` applies instantly through `PRICE_ORACLE_ROLE`, but only within a bounded deviation (±5%, `MAX_INSTANT_DEVIATION_BPS`). Larger jumps require `forceUpdatePrice`, gated by `DEFAULT_ADMIN_ROLE`, which is held by the timelock, so large or suspicious moves automatically get a review window while routine adjustments stay fast.

- **Timelock plus guardian cancellation for sensitive actions.** After deployment, `DEFAULT_ADMIN_ROLE` on all five contracts (validator, token, issuance, vault, distributor) moves from the deployer to a `TimelockController` (72h minimum delay). Guardians hold `CANCELLER_ROLE` and can block a malicious or mistaken action before it executes. Routine operational roles (whitelisting, depositing income, declaring dividends, instant price updates within bounds) are deliberately not timelocked: delaying frequent, already-bounded operations adds cost without much security. What *is* timelocked is changing who may perform them, replacing the compliance validator, and large price moves.

- **Defense-in-depth reentrancy protection.** `nonReentrant` guards the functions that move funds: `PropertyIssuance.purchase`, `DividendDistributor.claim`, and `RevenueVault.withdrawTo`. No exploit is reachable with a plain ERC-20 stablecoin, but the guard is cheap insurance if a hook-style token is ever integrated. A constructed hook-style malicious token and attacker contract verify this directly (see `test/security/`).

- **`SafeERC20` for all stablecoin transfers** (`PropertyIssuance`, `RevenueVault`), correctly handling non-standard tokens such as USDT's inconsistent return values.

- **Hard supply cap.** `PropertyToken` enforces an immutable `i_maxSupply` on every mint. A security token represents a fixed number of fractional shares, and the cap rules out unbounded dilution.

- **Solvency check at declaration time.** `declareDividends` compares the vault's live balance against all outstanding, unclaimed obligations plus the new round, so a round can never be declared that the vault cannot pay. This avoids a first-come-first-served race among holders.

---

## Contracts

### `WhitelistValidator.sol`
Maintains the compliance whitelist. `COMPLIANCE_ADMIN_ROLE` adds or removes addresses. `canTransfer(from, to, amount)` handles the mint (`from == address(0)`) and burn (`to == address(0)`) cases, requiring only the relevant party to be whitelisted.

### `PropertyToken.sol`
ERC-20 + `ERC20Votes` token (symbol `DKPT`, 18 decimals). `ISSUER_ROLE` can mint, capped by `i_maxSupply`. Every balance change is compliance-checked, new holders are auto-delegated to themselves, and delegation to other addresses is disabled.

### `PropertyIssuance.sol`
Primary issuance. A whitelisted buyer calls `purchase(tokenAmount)` and pays `tokenAmount * price / 1e18` in stablecoin, forwarded straight to a fixed `treasury`. Enforces a per-transaction maximum and rejects purchases whose cost would round to zero. `getMinPurchaseAmount()` exposes the smallest purchasable amount at the current price.

### `RevenueVault.sol`
Custodies stablecoin rental income. `DEPOSITOR_ROLE` deposits; only the `DISTRIBUTOR_ROLE` holder (the `DividendDistributor`) can withdraw, through `withdrawTo`.

### `DividendDistributor.sol`
`DIVIDEND_MANAGER_ROLE` declares rounds, snapshotting at `block.number - 1`, with a solvency check and a minimum-amount check that prevents degenerate, dust-rounding declarations. Holders call `claim(roundId)` for their proportional share, computed from their historical voting power at that round's snapshot. Eligibility persists after a holder sells: what counts is holding at the snapshot.

### Deployment parameters

| Parameter | Value |
| --- | --- |
| Max supply | 1,000,000 tokens |
| Initial price | 10 USDC per token |
| Max purchase per transaction | 100,000 tokens |
| Instant price deviation bound | ±5% |
| Timelock minimum delay | 72 hours |

---

## Roles and permissions

State of the current Sepolia deployment, as produced by `script/DeployTokenizedProperty.s.sol`:

| Contract | Role | Held by | Behind timelock? |
| --- | --- | --- | --- |
| `PropertyToken` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes (`setComplianceValidator`, role changes) |
| `PropertyToken` | `ISSUER_ROLE` | `PropertyIssuance` | Reassignment is timelocked |
| `PropertyIssuance` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes (`forceUpdatePrice`, role changes) |
| `PropertyIssuance` | `PRICE_ORACLE_ROLE` | Deployer | No: instant `updatePrice` within ±5% |
| `RevenueVault` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes |
| `RevenueVault` | `DEPOSITOR_ROLE` | Deployer | No: routine operation |
| `RevenueVault` | `DISTRIBUTOR_ROLE` | `DividendDistributor` | Reassignment is timelocked |
| `DividendDistributor` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes |
| `DividendDistributor` | `DIVIDEND_MANAGER_ROLE` | Deployer | No: routine operation |
| `WhitelistValidator` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes |
| `WhitelistValidator` | `COMPLIANCE_ADMIN_ROLE` | Deployer | No: whitelisting is an operational action |
| `TimelockController` | `PROPOSER_ROLE` | Deployer | n/a |
| `TimelockController` | `CANCELLER_ROLE` | Guardians (`GUARDIAN_1-3`), plus the proposer by OpenZeppelin default | n/a |
| `TimelockController` | `EXECUTOR_ROLE` | Anyone (`address(0)`) | n/a |
| `TimelockController` | `DEFAULT_ADMIN_ROLE` | The timelock itself (the deployer renounces it in the deploy script) | n/a |

---

## Live deployment (Sepolia)

All contracts are deployed and verified; source is readable on Etherscan.

| Contract | Address |
| --- | --- |
| WhitelistValidator | [`0xcAB07a5F798Fe39d91B3Dca8fcf93B5575880943`](https://sepolia.etherscan.io/address/0xcAB07a5F798Fe39d91B3Dca8fcf93B5575880943) |
| PropertyToken | [`0x4601DCB38c0480A530bdCa0B1D6012195b1DCb4d`](https://sepolia.etherscan.io/address/0x4601DCB38c0480A530bdCa0B1D6012195b1DCb4d) |
| PropertyIssuance | [`0xFeCBDaaF623F685C5e4CC3337261Ea863bD7454C`](https://sepolia.etherscan.io/address/0xFeCBDaaF623F685C5e4CC3337261Ea863bD7454C) |
| RevenueVault | [`0x131fe84284456942EAC9dDBF838f68Ea722cCDB6`](https://sepolia.etherscan.io/address/0x131fe84284456942EAC9dDBF838f68Ea722cCDB6) |
| DividendDistributor | [`0xe70fa8CF053d1dA9c94f374fe532A05e4cb72620`](https://sepolia.etherscan.io/address/0xe70fa8CF053d1dA9c94f374fe532A05e4cb72620) |
| TimelockController | [`0x597b050a8ae06D3cCf186714e7d398B517D21568`](https://sepolia.etherscan.io/address/0x597b050a8ae06D3cCf186714e7d398B517D21568) |
| Deployer (EOA) | [`0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631`](https://sepolia.etherscan.io/address/0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631) |
| Stablecoin (Circle testnet USDC) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |

> This deployment uses Circle's real Sepolia USDC test contract, with its genuine role-gated minting rather than a permissionless mock, so the demonstration reflects real stablecoin behavior.

---

## Live demonstration

The full lifecycle was executed on Sepolia with real testnet USDC. The scripts in `script/Interactions.s.sol` find the latest deployment through `DevOpsTools` (reading the local `broadcast/` logs) and send the corresponding transactions.

| Step | Script | Transaction |
| --- | --- | --- |
| 1. Purchase tokens | `Interactions.s.sol:PurchaseTokens` | [`0x9fb11520…657b8e`](https://sepolia.etherscan.io/tx/0x9fb11520a2e9aa0b18c84e67f250c58f084601e4fcb81ca0d2ad6cac14657b8e) |
| 2. Declare dividend | `Interactions.s.sol:DeclareDividend` | [`0x15184440…3c9e72`](https://sepolia.etherscan.io/tx/0x15184440591085994bf642755fe34d5ec15eec1b6c7cf84e23f09af62e3c9e72) |
| 3. Claim dividend | `Interactions.s.sol:ClaimDividend` | [`0xc1c938a0…5d0539`](https://sepolia.etherscan.io/tx/0xc1c938a06297a78b8b2a2f793f2e971516ec48588834c483494579ffb25d0539) |

---

## Dashboard

**[property-tokenization-nu.vercel.app](https://property-tokenization-nu.vercel.app)** (Sepolia, requires MetaMask)

A React app (`dashboard/`) built with Vite, TypeScript, and [viem](https://viem.sh).

- **Wallet handling:** connects through MetaMask, restores an existing session on reload, reacts to account and network changes, and prompts a switch to Sepolia when the wallet is on another network.
- **Wallet status:** shows the connected wallet's token balance and whitelist status.
- **Buying tokens:** the amount is adjustable and parsed exactly with `parseUnits` (no floating point), then validated against the contract's own limits (`getMinPurchaseAmount()` and `i_maxPurchasePerTx()`). The UI checks the current USDC allowance and asks for an exact-amount approval only when needed, then sends the purchase.
- **Claiming dividends:** lists every declared round with its claimed or unclaimed status and a claim button.

Design notes:

- Reads go through a public client with `multicall`, which batches many contract reads into one RPC request. Writes go through the user's wallet: the app never handles a private key.
- Client-side validation is a convenience only. The contracts independently enforce every rule.
- Purchases require the connected address to be whitelisted by the compliance admin. Any wallet can connect and view data, but a non-whitelisted wallet cannot buy.

---

## Tech stack

- **Solidity** `^0.8.30`
- **Foundry** (forge, cast, anvil): build, test, script, deploy
- **OpenZeppelin Contracts v5**: `AccessControl`, `ERC20Votes`, `SafeERC20`, `ReentrancyGuard`, `TimelockController`, `Math`
- **forge-std** and **foundry-devops** (`DevOpsTools`, used by the interaction scripts to find the latest deployment)
- **TypeScript + viem**: command-line read scripts (`client/`)
- **React 19 + Vite + viem**: web dashboard (`dashboard/`), deployed on Vercel
- **GitHub Actions**: CI on every push and pull request

---

## Getting started

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js 22+ (for the TypeScript parts).

```bash
cast wallet import deployer --interactive      # one-time setup

cp .env.example .env                            # then fill in the values below
source .env

forge script script/DeployTokenizedProperty.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account deployer --sender $DEPLOYER \
  --gas-estimate-multiplier 300 \
  --broadcast --verify
```

Environment variables (`.env`, which is git-ignored; see `.env.example`):

| Variable | Purpose |
| --- | --- |
| `SEPOLIA_RPC_URL` | RPC endpoint (Alchemy, Infura, ...) |
| `ETHERSCAN_API_KEY` | Contract verification (read by forge from the environment) |
| `DEPLOYER` | Address of the keystore account; must match `--account` |
| `TREASURY` | Address that receives purchase proceeds |
| `SEPOLIA_STABLECOIN_ADDRESS` | Stablecoin to use (Circle's Sepolia USDC) |
| `GUARDIAN_1`, `GUARDIAN_2`, `GUARDIAN_3` | Timelock cancellers; each defaults to the deployer if unset, so set all three to distinct addresses for real separation of duties |

Notes:

- `--sender` tells Foundry which address to simulate from; it must match the keystore account.
- **Gas on Sepolia:** after Sepolia's October 2026 gas-model upgrade, contract-creation transactions from Foundry 1.5.1 reverted out of gas because its local gas estimate came in too low. Updating Foundry and/or raising `--gas-estimate-multiplier` (as above) resolved it. If a deployment partly fails, discard it and run again from scratch.
- After deploying, update the contract addresses in `dashboard/src/abis_and_constants/constants.ts` and `client/src/abis_and_constants/constants.ts`.

### Interacting with a live deployment

The demo scripts locate the most recent deployment from the local `broadcast/` folder (that is why `foundry.toml` grants read access to it). They assume the broadcasting account already holds testnet USDC (get some at [faucet.circle.com](https://faucet.circle.com)) and must be run in order, because a dividend can only be declared once tokens exist:

```bash
forge script script/Interactions.s.sol:PurchaseTokens --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --gas-estimate-multiplier 300 --broadcast
forge script script/Interactions.s.sol:DeclareDividend --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --gas-estimate-multiplier 300 --broadcast
forge script script/Interactions.s.sol:ClaimDividend   --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --gas-estimate-multiplier 300 --broadcast
```

### Read scripts (`client/`)

TypeScript scripts that batch contract reads with `multicall` (token data, compliance status, purchase-flow state, dividend rounds):

```bash
cd client && npm install
npx tsx --env-file=../.env src/readers/dividends.ts <address> <roundId>
```

### Dashboard (`dashboard/`)

```bash
cd dashboard && npm install
cp .env.example .env        # set VITE_SEPOLIA_RPC_URL
npm run dev
```

Note: every `VITE_`-prefixed variable is embedded in the public JavaScript bundle. Use a dedicated key restricted to your domain, never a key that guards anything of value.

---

## Testing

154 tests, all passing: 128 unit, fuzz and integration tests across 8 suites, plus 26 invariant tests.

| Suite | Tests | Focus |
| --- | --- | --- |
| `WhitelistValidatorTest` | 16 | Whitelist management, `canTransfer` for mint, burn, and transfer |
| `PropertyTokenTest` | 27 | Compliance on transfer / `transferFrom` / mint, supply cap, zero-validator guard, auto-delegation, disabled delegation, voting-power checkpoints |
| `PropertyIssuanceTest` | 22 | Purchase flow, cost rounding, limits, bounded and forced price updates |
| `RevenueVaultTest` | 12 | Deposits, role-gated withdrawals, input validation |
| `DividendDistributorTest` | 24 | Rounds, solvency, proportional claims across holders and rounds |
| `TimelockTest` | 17 | Direct admin access is closed, delay is enforced, guardians can cancel, operational roles stay fast |
| `DeployTest` | 9 | The deployment script's contract wiring, role migration, and guardian setup |
| `ReentrancyExplorationTest` | 1 | A hook-style malicious token and attacker contract confirm the reentrancy guard |
| `ProtocolInvariant` | 26 | Stateful invariants (below) |

The unit suites combine directed tests (compliance scenarios, boundary conditions such as exactly-at-cap and one-second-before-delay) with fuzz tests (purchase amounts, proportional payouts, price-deviation bounds).

### Invariant tests

Invariant tests make Foundry call random sequences of user actions and check that properties hold after every call. `test/invariant/Handler.sol` is the guided set of actions the fuzzer may use: whitelist changes, purchases, transfers, dividend declarations, claims, attempted delegation, attempted compliance bypasses, and an attempted zero-address validator change. The handler keeps ghost variables, independent bookkeeping that the contracts' own state is compared against. `foundry.toml` runs 256 sequences of 100 calls.

| Group | Invariants | Examples |
| --- | --- | --- |
| Token and votes | 5 | Supply never exceeds the cap; actor balances sum to total supply; votes sum to supply; nobody can delegate their votes away |
| Compliance | 2 | A non-whitelisted address can never buy or transfer successfully; the validator is never the zero address |
| USDC conservation | 6 | Total USDC equals what the handler minted; issuer and distributor never hold USDC; the treasury holds exactly the purchase proceeds; the vault equals deposits minus claims |
| Dividend accounting | 10 | `s_totalOwed` equals declared minus claimed; each claim pays exactly the formula amount (measured, not recomputed); no double claims; payouts per round never exceed the round total; snapshot votes sum to snapshot supply |
| Pricing | 3 | Price is never zero; the minimum purchase never costs zero; cost rounding stays within one unit |

The invariants were validated by deliberately breaking the contracts and confirming the suite fails: claims overpaying by one unit, claims forgetting to update the ledger, and the zero-address guard removed were each caught. In the process, the suite also exposed two real issues that were fixed: dividends following delegated voting power instead of ownership, and a validator that could be set to the zero address.

**Coverage:** every contract in `src/` has 100% line, statement, branch, and function coverage. The deployment script is covered by `DeployTest`; the `Interactions` scripts and the Sepolia/mainnet branches of `HelperConfig` are exercised by live runs rather than unit tests.

**CI** (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, and `forge test` on every push and pull request.

```bash
forge test -vvv                       # verbose output, traces on failure
forge test --match-contract Timelock  # one suite
forge coverage --report summary
```

---

## Security considerations

**Addressed by design**

- Reentrancy: `nonReentrant` on every fund-moving entry point, verified with a constructed attack.
- Non-standard ERC-20 behavior: `SafeERC20` for all stablecoin transfers.
- Overflow in proportional math: `Math.mulDiv`.
- Dividend front-running: snapshot-based eligibility via `ERC20Votes`.
- Dividend redirection through delegation: delegation to other addresses is disabled, with unit tests and an invariant.
- Compliance freeze: the validator cannot be set to the zero address.
- Vault insolvency from over-declaration: the solvency check in `declareDividends`.
- Dust and free-mint rounding: `PropertyIssuance` rejects any purchase whose cost rounds to zero, and `DividendDistributor` rejects dividends too small for the current supply.
- Frontend trust: all rules are enforced on-chain; the UI cannot bypass them.

**Verification performed**

- Unit, fuzz and invariant tests as described above, with the invariants validated by deliberate fault injection.
- Slither static analysis on `src/`: no actionable findings remain. A strict-equality warning in `declareDividends` (`supply == 0`) is a false positive, since the value is a historical checkpoint that cannot be manipulated, and the remaining notes are naming-convention style (`s_` / `i_` prefixes), kept intentionally.

**Not done**

- No professional third-party audit.
- No formal verification.
- Dust rounding: a holder whose share of a dividend rounds to zero in the stablecoin's smallest unit cannot claim that round. This is inherent to on-chain integer division and negligible at realistic amounts.

### Known gaps in the current Sepolia deployment

Limitations of the deployed configuration:

1. **Single-key privileged roles.** The deployer, guardians, and treasury are single EOAs for simplicity and testability. How independent the guardians are depends on the addresses set through `GUARDIAN_1-3` at deployment; if they are left unset they default to the deployer, so the proposer and the canceller are the same key. The cancellation mechanism itself is covered by `TimelockTest` using independent guardian accounts. A production deployment should use distinct threshold multisigs (e.g., Safe).

---

## Known limitations and roadmap

1. **Multisig governance.** The deployer, guardians, and treasury are single EOAs here for simplicity and testability. A production deployment should use threshold multisigs (e.g., Safe) so no single compromised key can take a privileged action.
2. **Price oracle.** The hybrid instant/timelocked model reduces, but does not remove, trust in the `PRICE_ORACLE_ROLE` holder. A property has no continuous market price to aggregate, so an oracle would still be a trusted appraisal feed.
3. **Whitelist pre-check in the dashboard.** The purchase UI does not yet check whitelist status before offering "Approve", so a non-whitelisted wallet can spend gas on an approval before the purchase reverts. The check belongs in the UI as a convenience.
4. **Single-signature purchases.** Purchasing needs an approval transaction and a purchase transaction. Permit-style (EIP-2612 / authorization) flows would reduce this to one signature.
5. **Merkle-based distribution at scale.** The on-chain pull-based calculation fits this scale; a very large holder base could move to off-chain computation with Merkle-proof claims.
6. **Forced transfer / burn.** Regulated security tokens often need a compliance-triggered clawback; not implemented.
7. **Delegated governance.** Delegation is disabled because dividends follow voting power. Token-holder governance (e.g., an OpenZeppelin `Governor`) would need dividends computed from a separate balance history first.
8. **Threat model and external review.** Slither and invariant tests are done; a written threat model and an independent review remain.

---

## Project structure

```
├── src/                          # Solidity contracts
│   ├── WhitelistValidator.sol
│   ├── PropertyToken.sol
│   ├── PropertyIssuance.sol
│   ├── RevenueVault.sol
│   ├── DividendDistributor.sol
│   └── interfaces/IComplianceValidator.sol
├── script/                       # Foundry scripts
│   ├── DeployTokenizedProperty.s.sol
│   ├── HelperConfig.s.sol        # per-network configuration
│   └── Interactions.s.sol        # PurchaseTokens / DeclareDividend / ClaimDividend
├── test/
│   ├── unit/                     # per-contract suites, TimelockTest, DeployTest
│   ├── invariant/                # Handler.sol + Invariant.t.sol
│   ├── mocks/ReentrancyExploration.sol
│   └── security/ReentrancyExplorationTest.t.sol
├── client/                       # TypeScript read scripts (viem)
│   └── src/{readers, abis_and_constants}
├── dashboard/                    # React + Vite web dashboard
│   └── src/{interactions, abis_and_constants}
├── .github/workflows/test.yml    # CI
├── .env.example
├── foundry.toml
└── LICENSE
```

---

## Acknowledgments

Built on OpenZeppelin's audited contract libraries and informed by Cyfrin's Solidity and Foundry curriculum.

---

## License

MIT. See [LICENSE](LICENSE).