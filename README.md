# Property Tokenization Protocol

A compliance-gated, dividend-paying real-world asset (RWA) tokenization system built in Solidity with Foundry. Fractional ownership of a real-world property is represented as an ERC-20 token, restricted to whitelisted (KYC'd) holders, with snapshot-based dividend distribution of rental income and a timelock-protected governance layer guarding every sensitive admin action.

This project was designed and built end-to-end — architecture, contracts, tests, deployment tooling, and a live testnet demonstration — starting from an initial research conversation about asset tokenization trends, then developed through iterative design discussion, implementation, and security review.

---

## Table of contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Key design decisions](#key-design-decisions)
- [Contracts](#contracts)
- [Live deployment (Sepolia)](#live-deployment-sepolia)
- [Live demonstration](#live-demonstration)
- [Tech stack](#tech-stack)
- [Getting started](#getting-started)
- [Testing](#testing)
- [Security considerations](#security-considerations)
- [Known limitations & production roadmap](#known-limitations--production-roadmap)
- [Project structure](#project-structure)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## Overview

Real-world asset tokenization represents ownership of an off-chain asset (in this case, a property) as an on-chain token. This project implements a full, working system for that:

1. **Compliance-gated ownership** — tokens can only be minted to, held by, or transferred between whitelisted (KYC'd) addresses.
2. **Primary issuance** — whitelisted buyers purchase newly minted tokens directly with a stablecoin, at a price that can adjust in real time within safe bounds, or by governance for larger moves.
3. **Custody of rental income** — a dedicated vault holds stablecoin deposits representing the property's real-world income.
4. **Proportional dividend distribution** — token holders claim their share of declared dividends based on their historical token balance at the moment each dividend was declared (not their current balance), preventing last-minute buy-to-claim exploitation.
5. **Governance-protected administration** — every sensitive admin action (changing the compliance rules, reassigning operational roles, large price movements) is gated behind a 72-hour timelock with independent guardians able to cancel a malicious or mistaken action before it takes effect.

The system is fully deployed and verified on Sepolia, with a complete, real, on-chain demonstration of the purchase → dividend declaration → dividend claim lifecycle (see [Live demonstration](#live-demonstration)).

---

## Architecture

```
                     ┌────────────────────┐
                     │ WhitelistValidator │◄──────────────┐    
                     └─────────┬──────────┘               │ compliance
                    canTransfer│                          │ check
                               ▼                          │
┌────────────────┐     ┌──────────────────┐      ┌────────┴──────────┐
│PropertyIssuance├────►│  PropertyToken   │◄─────┤DividendDistributor│
│ (buy w/ USDC)  │ mint│  (ERC20Votes,    │ votes│ (snapshot-based   │
└───────┬────────┘     │  compliance hook,│      │  payouts, pull    │
        │ proceeds     │  auto-delegation,│      │  claims)          │
        ▼              │  max supply cap) │      └─────────┬─────────┘
   [treasury]          └──────────────────┘                │ withdrawTo
                                                           ▼
                                                   ┌───────────────┐
                                                   │  RevenueVault │◄── deposit   
                                                   |(rental income)|
                                                   └───────────────┘

                     ┌──────────────────────┐
                     │  TimelockController  │  governs DEFAULT_ADMIN_ROLE
                     │  (72h delay,         │  on every contract above
                     │   guardian cancel)   │
                     └──────────────────────┘
```

Each contract has a single, narrow responsibility:

| Contract | Responsibility |
|---|---|
| `WhitelistValidator` | Answers one question: can this address send/receive tokens? |
| `PropertyToken` | ERC-20 + ERC20Votes balances; enforces compliance on every transfer, mint, and burn via a single `_update` hook. |
| `PropertyIssuance` | Sells newly minted tokens to whitelisted buyers for stablecoin; adjustable pricing. |
| `RevenueVault` | Pure custody of stablecoin; releases funds only to the trusted `DividendDistributor`. |
| `DividendDistributor` | Tracks dividend rounds and lets holders claim their proportional, snapshot-based share. |
| `TimelockController` | Delays and allows cancellation of sensitive governance actions across every contract above. |

---

## Key design decisions

A number of deliberate architectural choices shape this system, each made to close a specific real-world risk:

- **Compliance as a pluggable hook, not hardcoded logic.** `PropertyToken` calls out to `WhitelistValidator` through a minimal `IComplianceValidator` interface via its `_update` override — the single choke point for every balance change (transfer, mint, burn). This mirrors the real-world separation between "who holds the asset" and "who's allowed to."

- **Snapshot-based dividends via `ERC20Votes`, not a naive current-balance model.** A holder's dividend eligibility for a given round is locked in at that round's declaration block, using OpenZeppelin's checkpoint mechanism (the same one used for on-chain governance voting power). This closes a real exploit: buying tokens right before a dividend and selling immediately after, to unfairly claim income never actually earned.

- **Auto-delegation on first token receipt.** `ERC20Votes` only checkpoints a holder's balance once they've delegated (even to themselves) — a well-known gotcha that could silently exclude holders from dividends if missed. `PropertyToken` auto-delegates each holder to themselves the first time they receive tokens, without overriding an existing deliberate delegation.

- **`Math.mulDiv` everywhere a proportional share is computed.** Naive `a * b / c` arithmetic can overflow at the multiplication step even when the true result fits safely in a `uint256`. Every dividend-share and purchase-cost calculation uses OpenZeppelin's full-precision `mulDiv`.

- **Hybrid real-time / timelocked pricing in `PropertyIssuance`.** Price updates within a bounded deviation (±5%, configurable via `MAX_INSTANT_DEVIATION_BPS`) apply instantly through a `PRICE_ORACLE_ROLE`. Larger jumps require `forceUpdatePrice`, gated by `DEFAULT_ADMIN_ROLE` — and since that role is migrated to the timelock, large or suspicious price movements automatically receive a mandatory review window, while routine adjustments stay fast.

- **Timelock + independent guardians over every `DEFAULT_ADMIN_ROLE`.** After deployment, `DEFAULT_ADMIN_ROLE` on every contract is migrated from the deploying EOA to a `TimelockController` (72-hour minimum delay). A dedicated set of guardian addresses — deliberately separate from whoever proposes changes — hold `CANCELLER_ROLE`, able to block a malicious or mistaken action (e.g., swapping in a fraudulent compliance validator) before it ever takes effect. Routine operational roles (minting via `PropertyIssuance`, depositing income, declaring dividends, instant price updates within bounds) are deliberately **not** timelocked, since delaying high-frequency, already-guarded operations would provide little security benefit at real operational cost.

- **Defense-in-depth reentrancy protection.** `nonReentrant` guards are applied to every function that performs more than one external call in sequence, even where no exploit is currently reachable with the tokens in use — cheap insurance against future integrations (e.g., a hook-style stablecoin) changing that assumption. This was explicitly verified with a constructed hook-style malicious token and reentrant attacker contract (see `test/security/`).

- **`SafeERC20` throughout.** All stablecoin transfers use OpenZeppelin's `SafeERC20`, correctly handling non-standard ERC-20 behavior (e.g., real USDT's inconsistent return values).

- **Hard supply cap.** `PropertyToken` enforces an immutable `i_maxSupply`, checked on every mint — a security token represents a fixed number of fractional shares, and the cap prevents unbounded dilution.

---

## Contracts

### `WhitelistValidator.sol`
Maintains the compliance whitelist. `COMPLIANCE_ADMIN_ROLE` can add/remove addresses. Exposes `canTransfer(from, to, amount)`, correctly handling the mint (`from == address(0)`) and burn (`to == address(0)`) cases.

### `PropertyToken.sol`
ERC-20 + `ERC20Votes` token representing fractional property ownership. `ISSUER_ROLE` can mint (capped by `i_maxSupply`); every balance change is compliance-checked and auto-delegates new holders to themselves.

### `PropertyIssuance.sol`
Primary issuance: whitelisted buyers call `purchase(tokenAmount)`, paying `tokenAmount * price / 1e18` in stablecoin, forwarded directly to a fixed `treasury` address. Price adjusts instantly within a bounded deviation (`PRICE_ORACLE_ROLE`) or by any amount via governance (`forceUpdatePrice`, timelocked).

### `RevenueVault.sol`
Custodies stablecoin rental income. `DEPOSITOR_ROLE` deposits funds; only the trusted `DISTRIBUTOR_ROLE` holder (the `DividendDistributor`) may withdraw, via `withdrawTo`.

### `DividendDistributor.sol`
`DIVIDEND_MANAGER_ROLE` declares dividend rounds (snapshotting eligibility at `block.number - 1`, with a solvency check against the vault's balance and a minimum-amount check to avoid degenerate, dust-rounding declarations). Holders `claim(roundId)` their proportional share, computed against their historical voting-power balance at that round's snapshot.

---

## Live deployment (Sepolia)

All contracts are deployed and verified — source code is publicly readable on Etherscan.

| Contract | Address |
|---|---|
| WhitelistValidator | [`0x7d3342950f772388F33D0789660aD0B6Aa731baD`](https://sepolia.etherscan.io/address/0x7d3342950f772388F33D0789660aD0B6Aa731baD) |
| PropertyToken | [`0x710559A196549934c67C4f7fa8917FE64C87B55F`](https://sepolia.etherscan.io/address/0x710559A196549934c67C4f7fa8917FE64C87B55F) |
| PropertyIssuance | [`0x9779dDB22f8c621B408556aaAaf5816F31a15Df2`](https://sepolia.etherscan.io/address/0x9779dDB22f8c621B408556aaAaf5816F31a15Df2) |
| RevenueVault | [`0x60ff418bD533c447dDD9247d05577797F5F7e5a4`](https://sepolia.etherscan.io/address/0x60ff418bD533c447dDD9247d05577797F5F7e5a4) |
| DividendDistributor | [`0xC32dD5de57e0DaE62F2D20BbEEfB4927BD82A476`](https://sepolia.etherscan.io/address/0xC32dD5de57e0DaE62F2D20BbEEfB4927BD82A476) |
| TimelockController | [`0xe02bae1314a30e649feeedc31ac652611f69ca66`](https://sepolia.etherscan.io/address/0xe02bae1314a30e649feeedc31ac652611f69ca66) |
| Deployer (EOA) | [`0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631`](https://sepolia.etherscan.io/address/0x95188FE733Ebc71c79d54fa2956d32Ef6d69f631) |
| Stablecoin (Circle testnet USDC) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |

> **Note:** this deployment uses Circle's real Ethereum Sepolia USDC testnet contract, with its genuine role-gated minting — not a permissionless mock — for a realistic demonstration.

---

## Live demonstration

The full purchase → dividend declaration → dividend claim lifecycle has been executed as real transactions on Sepolia, using real testnet USDC:

| Step | Script | Transaction |
|---|---|---|
| 1. Purchase tokens | `Interactions.s.sol:PurchaseTokens` | [`0x46191522041d3f1738e7c70f3fdd319235603ef9f0813c30cdb2dfc94c877e81`](https://sepolia.etherscan.io/tx/0x46191522041d3f1738e7c70f3fdd319235603ef9f0813c30cdb2dfc94c877e81) |
| 2. Declare dividend | `Interactions.s.sol:DeclareDividend` | [`0x01d5e0b00128e437c9fa8cba42b0eef757de0f749f3bf7f783e57e147d51ec77`](https://sepolia.etherscan.io/tx/0x01d5e0b00128e437c9fa8cba42b0eef757de0f749f3bf7f783e57e147d51ec77) |
| 3. Claim dividend | `Interactions.s.sol:ClaimDividend` | [`0x5a92146bf021e1d5e6532642390caf74a5b4777547daa268cee5e65618a6170f`](https://sepolia.etherscan.io/tx/0x5a92146bf021e1d5e6532642390caf74a5b4777547daa268cee5e65618a6170f) |

---

## Tech stack

- **Solidity** `^0.8.30`
- **Foundry** (forge, cast, anvil) — build, test, script, and deploy tooling
- **OpenZeppelin Contracts v5** — `AccessControl`, `ERC20Votes`, `SafeERC20`, `ReentrancyGuard`, `TimelockController`, `Math`
- **forge-std** — testing utilities and cheatcodes
- **foundry-devops** — `DevOpsTools` for locating the most recent deployment in interaction scripts

---

## Getting started

```bash
# Clone and install dependencies
git clone https://github.com/danushkka/property-tokenization
cd property-tokenization
forge install

# Build
forge build

# Run the full test suite
forge test

# Run tests with gas report
forge test --gas-report

# Check coverage
forge coverage
```

### Local deployment (Anvil)

```bash
# In one terminal
anvil

# In another terminal
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --private-key <anvil_account_private_key> --broadcast
```

### Testnet deployment (Sepolia)

This project uses Foundry's encrypted keystore feature rather than a plaintext private key:

```bash
# One-time setup
cast wallet import deployer --interactive

# Deploy
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --sender <deployer_address> --broadcast --verify
```

Required `.env` variables (see `.env.example`):

```
SEPOLIA_RPC_URL=
ETHERSCAN_API_KEY=
DEPLOYER_ADDRESS=
TREASURY_ADDRESS=
SEPOLIA_STABLECOIN_ADDRESS=
GUARDIAN_1=
GUARDIAN_2=
GUARDIAN_3=
```

### Interacting with a live deployment

```bash
forge script script/Interactions.s.sol:PurchaseTokens --rpc-url $SEPOLIA_RPC_URL --account deployer --sender <deployer_address> --broadcast
forge script script/Interactions.s.sol:DeclareDividend --rpc-url $SEPOLIA_RPC_URL --account deployer --sender <deployer_address> --broadcast
forge script script/Interactions.s.sol:ClaimDividend --rpc-url $SEPOLIA_RPC_URL --account deployer --sender <deployer_address> --broadcast
```

---

## Testing

The test suite covers every contract with 100% coverage, combining directed tests (specific compliance scenarios, boundary conditions) with fuzz tests (proportional payouts, arbitrary purchase amounts, deviation bounds) and a categorized approach for cross-cutting concerns:

- **Per-contract unit tests** — `WhitelistValidatorTest`, `PropertyTokenTest`, `RevenueVaultTest`, `DividendDistributorTest`, `PropertyIssuanceTest`
- **Governance/timelock tests** (`TimelockTest`) — categorized into: old direct-access shortcuts are closed; delay is enforced (including boundary cases); guardian cancellation works for any guardian and is rejected for non-guardians; operational roles remain fast and un-timelocked
- **Deployment tests** (`DeployTest`) — verifies contract wiring, role assignments, and configuration branches (provided vs. defaulted stablecoin/guardians) produced by the deployment script itself
- **Security exploration** (`test/security/`) — a constructed hook-style malicious token and reentrant attacker contract, used to directly verify `nonReentrant` protections rather than merely assuming they hold

```bash
forge test -vvv                      # verbose output with traces on failure
forge test --match-contract Timelock # run one suite
forge coverage                       # coverage report
```

---

## Security considerations

**Addressed by design:**
- Reentrancy — `nonReentrant` on every multi-external-call function, verified with a constructed attack.
- Non-standard ERC-20 tokens — `SafeERC20` throughout.
- Integer overflow in proportional math — `Math.mulDiv` for every multiply-then-divide calculation.
- Centralized admin risk — timelock + independent guardian cancellation on every `DEFAULT_ADMIN_ROLE`.
- Front-running dividend declarations — snapshot-based eligibility via `ERC20Votes`.
- Vault insolvency from over-declaration — `declareDividends` checks live vault balance against cumulative outstanding obligations before allowing a new round.

**Explicitly out of scope / deferred (see [Known limitations](#known-limitations--production-roadmap)):**
- This project has not undergone a professional third-party audit.
- Governance/guardian roles are represented by single EOAs in this deployment, not multisigs.
- Dust-rounding: a holder whose proportional share of a dividend rounds to zero (in the stablecoin's smallest unit) cannot claim that round — mathematically unavoidable with on-chain integer division, and negligible at realistic dividend/holding magnitudes.

---

## Known limitations & production roadmap

Honest gaps between this project and a production-grade deployment:

1. **Multisig governance.** `admin`, guardians, and `treasury` are single EOAs here for testability. A production deployment should use a threshold multisig (e.g., Safe) for each, so no single compromised key can take a privileged action.
2. **Price oracle.** The hybrid instant/timelocked pricing model mitigates but doesn't eliminate trust in whoever holds `PRICE_ORACLE_ROLE` — a genuinely decentralized, multi-reporter price oracle would be a substantial further undertaking, and arguably not warranted for a single, infrequently-appraised real-world asset.
3. **Merkle-based distribution at scale.** The current pull-based, on-chain proportional calculation is appropriate at this scale; a system with a very large holder base might move to an off-chain-computed, Merkle-proof-verified distribution to eliminate any on-chain division entirely.
4. **Forced transfer/burn.** Real regulated security tokens often need a compliance-triggered clawback mechanism (e.g., for a sanctioned holder) — not implemented here, noted as a deliberate scope boundary.
5. **On-chain holder governance.** `ERC20Votes` checkpointing is in place and could support a `Governor` contract for token-holder voting on protocol decisions; not implemented in this iteration.

---

## Project structure

```
├── src/
│   ├── WhitelistValidator.sol
│   ├── PropertyToken.sol
│   ├── PropertyIssuance.sol
│   ├── RevenueVault.sol
│   ├── DividendDistributor.sol
│   └── interfaces/
│       └── IComplianceValidator.sol
├── script/
│   ├── Deploy.s.sol
│   ├── HelperConfig.s.sol
│   └── Interactions.s.sol
├── test/
│   ├── WhitelistValidatorTest.t.sol
│   ├── PropertyTokenTest.t.sol
│   ├── RevenueVaultTest.t.sol
│   ├── DividendDistributorTest.t.sol
│   ├── PropertyIssuanceTest.t.sol
│   ├── TimelockTest.t.sol
│   ├── DeployTest.t.sol
│   └── security/
│       └── ReentrancyExplorationTest.t.sol
└── foundry.toml
```

---

## Acknowledgments

This project began as an exploration of asset tokenization trends and grew into a full implementation, informed by Cyfrin's Solidity and Foundry curriculum, OpenZeppelin's audited contract libraries, and iterative design review throughout development.

---

## License

MIT