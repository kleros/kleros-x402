# Kleros x x402 PoC

Proof of concept integrating [Kleros V2](https://github.com/kleros/kleros-v2) dispute resolution with [x402](https://github.com/x402-foundation/x402) auth-capture payments. Kleros is the operator of the escrow: the buyer's money is locked until the merchant is paid, the payer is refunded, or Kleros rules on who gets what.

The escrow is Coinbase's [commerce-payments](https://github.com/base/commerce-payments) `AuthCaptureEscrow` v1.1, consumed **untouched** and pinned as a git submodule at [6b0a5ef](https://github.com/base/commerce-payments/commit/6b0a5ef3f0df973857f558e2d6b5dd645b5e97f9). x402's auth-capture scheme lets a merchant name a custom operator for it; `KlerosCaptureAuthorizer` is that operator.

## Design

A payment ends in one of four ways: the dispute window passes and the merchant is paid; the payer releases it early; the merchant refunds it in full; or the payer disputes and Kleros rules. A partial refund only concedes that part; the rest still ends one of those ways. The lifecycle:

1. **The offer.** The merchant server's 402 names `KlerosCaptureAuthorizer` as a custom, collect-only operator, with no expiry and no fees. The SDK's merchant helper builds that part of the route.
2. **The payment.** The buyer pays through the SDK's fetch wrapper. It keeps the 402 verbatim in an agreement file and signs the payment with that file's keccak256 as `PaymentInfo.salt`, binding the payment to exactly the offer it was made against. The x402 facilitator verifies the payment and calls `authorize` on the operator, which locks the funds in the escrow and opens the dispute window.
3. **The window.** The payer can release early with `payerAccept`. The merchant can refund any amount with `merchantRefund`; refunding everything settles the payment. If the window passes silently, anyone calls `captureIfUnchallenged` and the merchant is paid.
4. **The dispute.** Within the window the payer calls `dispute`, paying the arbitration fee. The amount is clamped to what is still disputable; the undisputed remainder goes to the merchant at once, since no ruling can send it anywhere else. The agreement file is pinned and its URI stored with the dispute.
5. **The ruling.** Pay the merchant: the disputed amount is captured. Refund the payer: it is voided back. Refuse to arbitrate: the merchant is paid. `executeRuling` settles a ruling the arbitrator could not settle in its own transaction.

### Juror information

- **Dispute template and data mappings** ([template/](template/)) are registered on Kleros' template registry by the operator's constructor. The single mapping calls `getCaseData(disputeID)` on the operator, which returns everything the case page shows as one struct.
- **The agreement** is linked on the case page next to the agreement hash, the payment's salt. A juror downloads the file and checks `cast keccak < agreement.json` against the hash: a match means the file is the offer the payer paid against, and neither party can claim other terms.
- **The dispute policy** ([template/policy.md](template/policy.md), pinned at `/ipfs/QmUXtVE2gGzWtYYhM68XTQMcDDfYFXkgTgeeVUXDbQwUnA`) tells jurors how to establish the offer from the agreement or, failing that, from the evidence; how to compare the delivery with it; and that the payer bears the burden of proof. A mock policy for the PoC.

### Decisions & PoC limitations

- **Collect-only operator.** The facilitator relays `authorize` and nothing else; capture and refund are the operator's own calls, driven by the window, the parties or the ruling. The 402 therefore carries `paymentFlow: "escrow"`, `captureMode: "deferred"` and `receiverAuthorizer: zeroAddress`, and `charge` is disabled on the operator.
- **No expiry on the escrow authorization.** Capture and refund deadlines are the largest `uint48`, so no ruling can arrive too late. The operator refuses deadlines shorter than its dispute window plus an arbitration buffer.
- **Only the payer can dispute.** Silence pays the merchant, so the payer is the only party it can hurt.
- **Refuse to arbitrate pays the merchant.** Refusing to arbitrate should not change the normal payment flow. Refund by default would let a payer win by making a case the jurors cannot decide.
- **No arbitration fee return.** The payer pays the fee and is not refunded, even if he wins. Must be improved for a production deployment.
- **No fees to the operator.** The fee fields exist in the 402 and the contract forwards whatever they say, so a fee can be introduced without a contract change.
- **No exit if the Court never rules.** The funds stay in escrow until a ruling is executed. A stale-dispute path was considered and left out of the PoC.
- **Own buyer client for this scheme.** x402's fetch wrapper decodes the 402 before any hook sees its raw bytes, which the agreement needs, and its auth-capture client draws a random salt with no way to set one. The SDK replaces both for this scheme, built on x402's types, header codecs, signer interface and payload format, so what reaches the merchant server and the facilitator is the official payload with the agreement hash as salt. Merchant server and facilitator are x402's own.
- **Amounts on the case page are in the token's base units.** The Court renders what the mapping returns; formatting by decimals belongs in the Court's template engine.
- **The template is immutable.** Registered once at construction; changing it means redeploying the operator.
- **Own escrow on the test network.** Coinbase's canonical escrow is not deployed on Arbitrum Sepolia, so the PoC deploys its own copy there. In production the operator is deployed against the canonical escrow and collector of its network.

## Testnet deployment

All contracts are deployed and verified on Arbitrum Sepolia, interacting with the Kleros v2 testnet and using the Agentic Commerce Court (court 8), 3 jurors per dispute, classic dispute kit, arbitration cost 0.00081 ETH. The operator's dispute window is 3 days and its arbitration buffer 7 days.

| Contract                                                      | Address                                      |
| ------------------------------------------------------------- | -------------------------------------------- |
| AuthCaptureEscrow v1.1 (our deployment, their code untouched) | `0x3e1e17725899ce96AF5C95b9f95a9c74588cf622` |
| ERC3009PaymentCollector                                       | `0xE96E9f608fE62a8A8A29cf1B9BBAE33799DaF8e3` |
| KlerosCaptureAuthorizer (the operator)                        | `0x729CeC589286515A9bF28Fcdf0e71D2f94fAf674` |
| Payment token (Circle testnet USDC)                           | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Kleros KlerosCore                                             | `0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479` |
| Kleros DisputeTemplateRegistry                                | `0xe763d31Cb096B4bc7294012B78FC7F148324ebcb` |

## Demo

*To be run.* Every settlement path is to run on the real testnet court, against the contracts above, through the official x402 merchant server and facilitator built from x402 `main`:

- **Unchallenged capture**: paid, window passes, `captureIfUnchallenged` pays the merchant.
- **Early release**: paid, `payerAccept` pays the merchant inside the window.
- **Full concession**: paid, `merchantRefund` of the full amount voids it back to the payer.
- **Full dispute**: paid, disputed in full, ruled at the Court, executed.
- **Partial dispute**: paid, part disputed, remainder captured at dispute time, the rest ruled.

| Case  | Scenario | Ruling |
| ----- | -------- | ------ |
| *tbd* |          |        |

### Rails

The merchant server and the facilitator are x402's own, run with the operator on the facilitator's custom-operator allowlist. Two things about running them for the demo:

- Their auth-capture entry points landed on x402 `main` with PR #3203 (merged 2026-10-06) and are unreleased: `@x402/evm` 2.28.0 ships the client only. Both run `@x402/evm` built from `main`.
- They only know Coinbase's canonical escrow addresses, from the table in `src/auth-capture/constants.ts`. On the test network the build adds our escrow and collector to that table; otherwise the server rewrites `authCaptureEscrow` to the canonical address and the facilitator checks the payment against contracts with no code on Arbitrum Sepolia. In production, against the canonical escrow, nothing is added.
- The facilitator verifies a custom operator by simulating the `authorize` call, so its signer needs an RPC that supports `eth_simulateV1`. Arbitrum's public endpoint does.

## Repository layout

- [src/KlerosCaptureAuthorizer.sol](src/KlerosCaptureAuthorizer.sol): the operator, with its Foundry tests under [test/](test/).
- [template/](template/): dispute template, data mappings and the juror policy.
- [script/](script/): the deploy scripts.
- [sdk/](sdk/): the TypeScript SDK for merchants and buyers, with its own [README](sdk/README.md).

## Setup

Requires [Foundry](https://getfoundry.sh/) and Node 22.18 or later for the SDK.

```bash
git clone --recursive git@github.com:kleros/kleros-x402.git
```

If already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Build & test

```bash
forge build
```

```bash
forge test
```

```bash
cd sdk && npm install && npm test
```

## Reproducing the deployment

```bash
forge script script/DeployEscrow.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $DEPLOYER_PK --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY
```

deploys the escrow and its ERC-3009 collector; the escrow's constructor also deploys a `TokenStore` implementation, verified separately with `forge verify-contract`. Put the escrow address into `ESCROW` in [script/DeployOperator.s.sol](script/DeployOperator.s.sol), then

```bash
forge script script/DeployOperator.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $DEPLOYER_PK --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY
```

deploys the operator, registering the dispute template from `template/`. Verification needs a recent Foundry, one that uses Etherscan's V2 API: 1.5.1 works, 1.1.0 does not. After a deploy, the addresses go into [sdk/src/deployments.ts](sdk/src/deployments.ts).
