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
 ┌────────────────────┐ 
 | WhitelistValidator |           
 |  (KYC whitelist)   |
 └────────────────────┘
           | canTransfer
           ▼
 ┌──────────────────┐   mint    ┌───────────────────────┐  
 │ PropertyIssuance │──────────►│     PropertyToken     |              
 |  (buy with USDC) |           |  (ERC20Votes, supply  |
 └──────────────────┘           | cap, compliance hook) |
          │ USDC proceeds       └───────────┬───────────┘
          ▼                                 │ getPastVotes /
      [treasury]                            │ getPastTotalSupply
                                            ▼
 ┌───────────────┐   withdrawTo   ┌───────────────────────┐
 │ RevenueVault  │◄───────────────│  DividendDistributor  │
 │ (USDC income) │                │ (rounds, pull claims) │
 └───────────────┘                └───────────────────────┘
        ▲ deposit (DEPOSITOR_ROLE)

 ┌─────────────────────────────────────────────────────────┐
 │ TimelockController: 72h delay, guardian cancellation    │
 │ holds DEFAULT_ADMIN_ROLE on all five contracts above    │
 │              (see Roles and permissions)                │
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

- **Compliance as a pluggable hook.** `PropertyToken` asks `WhitelistValidator`, through a minimal `IComplianceValidator` interface, whether each transfer is allowed. It does this in its `_update` override, the single choke point for every balance change (transfer, mint, burn), so no path can skip the check.

- **Snapshot-based dividends via `ERC20Votes`.** A holder's eligibility for a round is fixed at the block before that round was declared, using OpenZeppelin's checkpoint mechanism. This closes an exploit where someone buys tokens right before a dividend and sells right after.

- **Auto-delegation on first receipt.** `ERC20Votes` only checkpoints a holder's balance once they have delegated (even to themselves), which would silently exclude holders from dividends. `PropertyToken` self-delegates each new holder on first receipt, without overriding an existing deliberate delegation.

- **`Math.mulDiv` for every proportional calculation.** A plain `a * b / c` can overflow at the multiplication even when the true result fits in a `uint256`. Dividend shares and purchase costs use OpenZeppelin's full-precision `mulDiv`.

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
ERC-20 + `ERC20Votes` token (symbol `DKPT`, 18 decimals). `ISSUER_ROLE` can mint, capped by `i_maxSupply`. Every balance change is compliance-checked, and new holders are auto-delegated to themselves.

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

State of the current Sepolia deployment: the deploy script's output plus the [post-deployment governance steps](#post-deployment-governance-steps) listed below.

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
| `WhitelistValidator` | `DEFAULT_ADMIN_ROLE` | TimelockController | Yes (migrated after deployment) |
| `WhitelistValidator` | `COMPLIANCE_ADMIN_ROLE` | Deployer | No: whitelisting is an operational action and stays instant || `TimelockController` | `PROPOSER_ROLE` | Deployer | n/a |
| `TimelockController` | `EXECUTOR_ROLE` | Anyone (`address(0)`) | n/a |
| `TimelockController` | `CANCELLER_ROLE` | Deployer (all three guardian slots defaulted to it; see [known gaps](#known-gaps-in-the-current-sepolia-deployment)) | n/a |
| `TimelockController` | `DEFAULT_ADMIN_ROLE` | The timelock itself (the deployer renounced it after setup) | n/a |
---

## Live deployment (Sepolia)

All contracts are deployed and verified; source is readable on Etherscan.

| Contract | Address |
| --- | --- |
| WhitelistValidator | [`0x7d3342950f772388F33D0789660aD0B6Aa731baD`](https://sepolia.etherscan.io/address/0x7d3342950f772388F33D0789660aD0B6Aa731baD) |
| PropertyToken | [`0x710559A196549934c67C4f7fa8917FE64C87B55F`](https://sepolia.etherscan.io/address/0x710559A196549934c67C4f7fa8917FE64C87B55F) |
| PropertyIssuance | [`0x9779dDB22f8c621B408556aaAaf5816F31a15Df2`](https://sepolia.etherscan.io/address/0x9779dDB22f8c621B408556aaAaf5816F31a15Df2) |
| RevenueVault | [`0x60ff418bD533c447dDD9247d05577797F5F7e5a4`](https://sepolia.etherscan.io/address/0x60ff418bD533c447dDD9247d05577797F5F7e5a4) |
| DividendDistributor | [`0xC32dD5de57e0DaE62F2D20BbEEfB4927BD82A476`](https://sepolia.etherscan.io/address/0xC32dD5de57e0DaE62F2D20BbEEfB4927BD82A476) |
| TimelockController | [`0xe02bae1314a30e649feeedc31ac652611f69ca66`](https://sepolia.etherscan.io/address/0xe02bae1314a30e649feeedc31ac652611f69ca66) |
| Deployer (EOA) | [`0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631`](https://sepolia.etherscan.io/address/0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631) |
| Stablecoin (Circle testnet USDC) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |

> This deployment uses Circle's real Sepolia USDC test contract, with its genuine role-gated minting rather than a permissionless mock, so the demonstration reflects real stablecoin behavior.

### Post-deployment governance steps

Two governance steps were done after the deploy script ran, as direct transactions:

| Step | Transaction |
| --- | --- |
| Deployer renounced its `DEFAULT_ADMIN_ROLE` on the TimelockController | [`0xd1b2bb82…c4b0f`](https://sepolia.etherscan.io/tx/0xd1b2bb8263963a03ff475e4c9f5dea4d566c1636e60ca3142d9d417db03c4b0f) |
| Granted `DEFAULT_ADMIN_ROLE` on WhitelistValidator to the timelock | [`0x65696e8f…d3236`](https://sepolia.etherscan.io/tx/0x65696e8f926c7b2d520b0ed0ee08360e5532074674980512ed29e164970d3236) |
| Revoked the deployer's `DEFAULT_ADMIN_ROLE` on WhitelistValidator | [`0x1975de53…61acb`](https://sepolia.etherscan.io/tx/0x1975de534e17719db70ad8ed52970c5cd0411a8739f716d219dbd16d26061acb) |
---

## Live demonstration

The full lifecycle was executed on Sepolia with real testnet USDC: 5 tokens bought for 50 USDC, a 25 USDC dividend declared as round 0, then claimed.

| Step | Script | Transaction |
| --- | --- | --- |
| 1. Purchase tokens | `Interactions.s.sol:PurchaseTokens` | [`0x46191522…877e81`](https://sepolia.etherscan.io/tx/0x46191522041d3f1738e7c70f3fdd319235603ef9f0813c30cdb2dfc94c877e81) |
| 2. Declare dividend | `Interactions.s.sol:DeclareDividend` | [`0x01d5e0b0…51ec77`](https://sepolia.etherscan.io/tx/0x01d5e0b00128e437c9fa8cba42b0eef757de0f749f3bf7f783e57e147d51ec77) |
| 3. Claim dividend | `Interactions.s.sol:ClaimDividend` | [`0x5a92146b…a6170f`](https://sepolia.etherscan.io/tx/0x5a92146bf021e1d5e6532642390caf74a5b4777547daa268cee5e65618a6170f) |

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
git clone --recurse-submodules https://github.com/danushkka/property-tokenization.git
cd property-tokenization

forge build
forge test
forge coverage --report summary
```

### Local deployment (Anvil)

```bash
# Terminal 1
anvil

# Terminal 2: broadcast with one of Anvil's pre-funded accounts, and tell the
# config which address that key belongs to
export ANVIL_DEPLOYER=<address of that account>
forge script script/DeployTokenizedProperty.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <that account's private key> \
  --broadcast
```

On Anvil, `HelperConfig` deploys a mock stablecoin and uses deterministic placeholder addresses for the guardians and treasury.

### Testnet deployment (Sepolia)

The deployer key is stored in Foundry's encrypted keystore rather than in a file:

```bash
cast wallet import deployer --interactive      # one-time setup

cp .env.example .env                            # then fill in the values below
source .env

forge script script/DeployTokenizedProperty.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account deployer --sender $DEPLOYER \
  --broadcast --verify
```

Environment variables (`.env`, which is git-ignored):

| Variable | Purpose |
| --- | --- |
| `SEPOLIA_RPC_URL` | RPC endpoint (Alchemy, Infura, ...) |
| `ETHERSCAN_API_KEY` | Contract verification (read by forge from the environment) |
| `DEPLOYER` | Address of the keystore account; must match `--account` |
| `TREASURY` | Address that receives purchase proceeds |
| `SEPOLIA_STABLECOIN_ADDRESS` | Stablecoin to use (Circle's Sepolia USDC) |
| `GUARDIAN_1`, `GUARDIAN_2`, `GUARDIAN_3` | Timelock cancellers; each defaults to the deployer if unset, so set all three for real separation of duties |

The `--sender` flag tells Foundry which address to simulate from. It must match the keystore account.

### Interacting with a live deployment

The demo scripts locate the most recent deployment from the local `broadcast/` folder (that is why `foundry.toml` grants read access to it). They assume the broadcasting account already holds testnet USDC (get some at [faucet.circle.com](https://faucet.circle.com)) and must be run in order, because a dividend can only be declared once tokens exist:

```bash
forge script script/Interactions.s.sol:PurchaseTokens --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --broadcast
forge script script/Interactions.s.sol:DeclareDividend --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --broadcast
forge script script/Interactions.s.sol:ClaimDividend   --rpc-url $SEPOLIA_RPC_URL --account deployer --sender $DEPLOYER --broadcast
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

123 tests across 8 suites, all passing:

| Suite | Tests | Focus |
| --- | --- | --- |
| `WhitelistValidatorTest` | 16 | Whitelist management, `canTransfer` for mint, burn, and transfer |
| `PropertyTokenTest` | 23 | Compliance on transfer / `transferFrom` / mint, supply cap, auto-delegation, voting-power checkpoints |
| `PropertyIssuanceTest` | 22 | Purchase flow, cost rounding, limits, bounded and forced price updates |
| `RevenueVaultTest` | 12 | Deposits, role-gated withdrawals, input validation |
| `DividendDistributorTest` | 23 | Rounds, solvency, proportional claims across holders and rounds |
| `TimelockTest` | 17 | Direct admin access is closed, delay is enforced, guardians can cancel, operational roles stay fast |
| `DeployTest` | 9 | The deployment script's contract wiring, role migration, and guardian setup |
| `ReentrancyExplorationTest` | 1 | A hook-style malicious token and attacker contract confirm the reentrancy guard |

The suites combine directed tests (compliance scenarios, boundary conditions such as exactly-at-cap and one-second-before-delay) with fuzz tests (purchase amounts, proportional payouts, price-deviation bounds).

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
- Vault insolvency from over-declaration: the solvency check in `declareDividends`.
- Dust and free-mint rounding: `PropertyIssuance` rejects any purchase whose cost rounds to zero, and `DividendDistributor` rejects dividends too small for the current supply.
- Frontend trust: all rules are enforced on-chain; the UI cannot bypass them.

**Not done**

- No professional third-party audit.
- Static analysis (Slither) and Foundry invariant tests have not been run yet.
- Dust rounding: a holder whose share of a dividend rounds to zero in the stablecoin's smallest unit cannot claim that round. This is inherent to on-chain integer division and negligible at realistic amounts.

### Known gaps in the current Sepolia deployment

Limitations of the deployed configuration:

1. **Guardians are not independent in this deployment.** All three guardian slots defaulted to the deployer address (`GUARDIAN_*` were not set), so the same key that proposes an action can also cancel it. The cancellation mechanism itself is covered by `TimelockController` tests that use independent guardian accounts. A real deployment must set three distinct addresses, ideally multisigs. The deployer's admin role on the timelock was renounced after setup, so changing proposers, executors, or guardians now requires a 72-hour timelocked proposal.
2. **All privileged roles are single EOAs** rather than multisigs (see below).

---

## Known limitations and roadmap

1. **Multisig governance.** The deployer, guardians, and treasury are single EOAs here for simplicity and testability. A production deployment should use threshold multisigs (e.g., Safe) so no single compromised key can take a privileged action.
2. **Price oracle.** The hybrid instant/timelocked model reduces, but does not remove, trust in the `PRICE_ORACLE_ROLE` holder. A property has no continuous market price to aggregate, so an oracle would still be a trusted appraisal feed.
3. **Whitelist pre-check in the dashboard.** The purchase UI does not yet check whitelist status before offering "Approve", so a non-whitelisted wallet can spend gas on an approval before the purchase reverts. The check belongs in the UI as a convenience.
4. **Single-signature purchases.** Purchasing needs an approval transaction and a purchase transaction. Permit-style (EIP-2612 / authorization) flows would reduce this to one signature.
5. **Merkle-based distribution at scale.** The on-chain pull-based calculation fits this scale; a very large holder base could move to off-chain computation with Merkle-proof claims.
6. **Forced transfer / burn.** Regulated security tokens often need a compliance-triggered clawback; not implemented.
7. **Holder governance.** `ERC20Votes` checkpointing is in place and could support an OpenZeppelin `Governor` for token-holder voting.
8. **Security review pass.** Slither static analysis, Foundry invariant tests, and a written threat model.

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
│   ├── *Test.t.sol               # per-contract suites, TimelockTest, DeployTest
│   ├── mocks/ReentrancyExploration.sol
│   └── security/ReentrancyExplorationTest.t.sol
├── client/                       # TypeScript read scripts (viem)
│   └── src/{readers, abis_and_constants}
├── dashboard/                    # React + Vite web dashboard
│   └── src/{interactions, abis_and_constants}
├── .github/workflows/test.yml    # CI
└── foundry.toml
```

---

## Acknowledgments

Built on OpenZeppelin's audited contract libraries and informed by Cyfrin's Solidity and Foundry curriculum.

---

## License

MIT