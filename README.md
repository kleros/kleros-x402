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

All contracts are deployed and verified on Arbitrum Sepolia, interacting with the Kleros v2 testnet and using the Agentic Commerce Court (court 8), 3 jurors per dispute, classic dispute kit, arbitration cost 0.00081 ETH. The operator's dispute window is 10 minutes, a test value so that every demo path completes within the hour; a real deployment gives the payer days. Its arbitration buffer is 7 days.

| Contract                                                      | Address                                      |
| ------------------------------------------------------------- | -------------------------------------------- |
| AuthCaptureEscrow v1.1 (our deployment, their code untouched) | `0x3e1e17725899ce96AF5C95b9f95a9c74588cf622` |
| ERC3009PaymentCollector                                       | `0xE96E9f608fE62a8A8A29cf1B9BBAE33799DaF8e3` |
| KlerosCaptureAuthorizer (the operator)                        | `0x6B4E7055e0aDdB5F31A39b5f2719da843b1Bc4c9` |
| Payment token (Circle testnet USDC)                           | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Kleros KlerosCore                                             | `0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479` |
| Kleros DisputeTemplateRegistry                                | `0xe763d31Cb096B4bc7294012B78FC7F148324ebcb` |

## Demo

Every settlement path ran on the real testnet court, against the contracts above, through the official x402 merchant server and facilitator, built from x402 `main` before their 2.29.0 release:

- **Unchallenged capture**: paid, window passes, `captureIfUnchallenged` pays the merchant.
- **Early release**: paid, `payerAccept` pays the merchant inside the window.
- **Full concession**: paid, `merchantRefund` of the full amount voids it back to the payer.
- **Full dispute**: paid, disputed in full, ruled at the Court, executed.
- **Partial dispute**: paid, part disputed, remainder captured at dispute time, the rest ruled.

| Scenario | Payment | Settlement | Case | Ruling |
| -------- | ------- | ---------- | ---- | ------ |
| Unchallenged capture | `0xd595…7080` | `captureIfUnchallenged` [`0x3c6d…5384`](https://sepolia.arbiscan.io/tx/0x3c6d0fdac327ac78fd16faba08f88eddcb66c025eea5c6a5675001e2a6ed5384) | | |
| Early release | `0xafe9…af4b` | `payerAccept` [`0x8a20…17a5`](https://sepolia.arbiscan.io/tx/0x8a20d27353e6b01da146bafd50b0736286d8b9b37ed75f5574ca63925f0517a5) | | |
| Full concession | `0xeeef…b637` | `merchantRefund` [`0x5e83…dd45`](https://sepolia.arbiscan.io/tx/0x5e8392f7e58e20e14474690ed6e9d7232a0128113ab1882615dbca22d983dd45) | | |
| Full dispute | `0x678a…069b` | `dispute` [`0xe8e7…764d`](https://sepolia.arbiscan.io/tx/0xe8e7ff650a61eb919e70d19fd7ad7fcf8b8a8a9f9b4ca383db7f1bcc0851764d) | [191](https://v2-testnet.kleros.builders/#/cases/191/overview) | Pay the merchant, executed in [`0x8750…e354`](https://sepolia.arbiscan.io/tx/0x87506acf7d7552ae7197f632b00e6a6cae29cec8dd5aab8b6a737c7910bde354) |
| Partial dispute | `0x2adc…4e16` | `dispute` [`0x99d2…118a`](https://sepolia.arbiscan.io/tx/0x99d2a0a89ef62069d0756aa8fd89e570fdeae1cd757e2654da4952057650118a), 5000 of 10000 captured at once | [192](https://v2-testnet.kleros.builders/#/cases/192/overview) | Refuse to arbitrate, paid to the merchant by the operator's rule, executed in [`0xb133…d645`](https://sepolia.arbiscan.io/tx/0xb133f4715ae0ac5bac0327cfefa18abc2b7550a2547cfab9d3ab603f4d63d645) |

Both cases were decided by the same juror, an AI juror holding all three seats. Its refuse-to-arbitrate vote on 192 came from a failed read of the template on its side, documented in its own justification; the case page itself rendered throughout.

### Rails

The merchant server and the facilitator are x402's own example apps, [demo/merchant.ts](demo/merchant.ts) and [demo/facilitator.ts](demo/facilitator.ts), copied from the pinned x402 submodule with Arbitrum Sepolia as the network. The merchant's route is built with the SDK; the facilitator has the operator on its custom-operator allowlist. The buyer is the SDK's fetch wrapper, run by [demo/buy.ts](demo/buy.ts), and the calls while the payment is in escrow are made by [demo/settle.ts](demo/settle.ts). Three things about running them for the demo:

- Their auth-capture entry points shipped in `@x402/evm` 2.29.0 on 2026-10-28. The demo still builds `@x402/core`, `@x402/extensions`, `@x402/evm` and `@x402/express` from the submodule, pinned at the release commit `e4a0868`, with [demo/build-x402.sh](demo/build-x402.sh), because of the next point.
- They only know Coinbase's canonical escrow addresses, from the table in `src/auth-capture/constants.ts`; otherwise the server rewrites `authCaptureEscrow` to the canonical address and the facilitator checks the payment against contracts with no code on Arbitrum Sepolia. The build applies [demo/x402-arbitrum-sepolia-escrow.patch](demo/x402-arbitrum-sepolia-escrow.patch), which adds our escrow and collector to that table, and reverts it afterwards. In production, against the canonical escrow, nothing is patched.
- The facilitator verifies a custom operator by simulating the `authorize` call, so its signer needs an RPC that supports `eth_simulateV1`. Arbitrum's public endpoint does. Its gas cap for that call is 1,000,000; `authorize` uses about 380,000 in the Foundry suite.

### Running it

Copy `demo/.env.example` to `demo/.env` and fill it in: the facilitator's key, the merchant's address and key, the buyer's key, and a Pinata JWT for disputes. The facilitator pays gas for `authorize`, the buyer pays in USDC plus the arbitration cost in ETH, the merchant pays gas for refunds. Then, from `demo/`, each in its own terminal and in this order:

```bash
npm run facilitator
```

```bash
npm run merchant
```

Then one scenario per call, each a purchase followed by its settlement path:

```bash
npm run demo -- <scenario>
```

`capture` waits for the window to close and captures; `release` calls `payerAccept`; `refund` refunds everything; `dispute` and `partial` open a case over the full amount or half, pinning the agreement, and print the case id and its Court link.

The steps are also available one at a time:

```bash
npm run buy
```

`buy` prints the payment hash. Then, while the payment is in escrow:

```bash
npm run settle -- <action> <paymentHash> [amount]
```

where `action` is `payment` to read it, `payerAccept`, `merchantRefund <amount>`, `dispute <amount>`, `captureIfUnchallenged` or `executeRuling`. Amounts are in the token's base units, as in the 402: the demo's price of 0.01 USDC is `10000`. `dispute` pins the agreement from `demo/payments/` and prints the Court case.

## Repository layout

- [src/KlerosCaptureAuthorizer.sol](src/KlerosCaptureAuthorizer.sol): the operator, with its Foundry tests under [test/](test/).
- [template/](template/): dispute template, data mappings and the juror policy.
- [script/](script/): the deploy scripts.
- [sdk/](sdk/): the TypeScript SDK for merchants and buyers, with its own [README](sdk/README.md).
- [demo/](demo/): the rails of the demo, x402's facilitator and merchant server built from their 2.29.0 release, and the buyer and settlement scripts on the SDK.
- [lib/](lib/): the submodules, commerce-payments and x402.

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
cd sdk && npm install && npm test && npm run build
```

The demo links the SDK's build. Its own build compiles the x402 packages from the submodule, about a minute the first time:

```bash
cd demo && npm run build:x402 && npm install && npm test
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
