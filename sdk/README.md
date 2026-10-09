# kleros-x402-sdk

Kleros dispute resolution for x402 auth-capture payments. The merchant's 402 names `KlerosCaptureAuthorizer` as the escrow's operator; the buyer pays with the hash of that 402 as the payment's salt; the payer can dispute at Kleros while the funds sit in escrow, and the operator settles according to the ruling. Design, contracts and deployed addresses are in the [repository README](../README.md).

## What the SDK provides

- For the merchant: `klerosX402PaymentOption`, the payment option of a route sold under Kleros arbitration.
- For the buyer: `klerosX402Fetch`, a `fetch` that pays such 402s and keeps the records a dispute needs.
- For either party: `klerosX402Client`, the dispute, release, refund and capture calls on the operator contract.

The merchant server, the facilitator and the escrow are x402's and run unchanged; the facilitator must have the operator on its custom-operator allowlist. Supported network contract addresses are in `src/deployments.ts`.

**Note:** As of `@x402/evm` 2.28.0 the auth-capture server and facilitator are unreleased and run from a build of x402 `main`.

## Build and test

```bash
npm install && npm test && npm run build
```

## Merchant

Called once per route, where the server defines its routes; nothing runs per request. The merchant chooses the network, the payment token (`token` is its EIP-712 domain name and version), `payTo` and `price`, and may set `maxTimeoutSeconds` on the route, which buyers refuse above their own limit, 300 by default.

The SDK fills in the rest of the offer: scheme, our operator and the escrow it was deployed against, escrow flow with deferred capture, EIP-3009, no expiry, no fees, no salt binding. The scheme server must be registered with `collectOnlyRoutes: true`.

```ts
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/server";
import { klerosX402PaymentOption } from "kleros-x402-sdk";

const server = new x402ResourceServer(facilitatorClient).register("eip155:421614", new AuthCaptureEvmScheme({ collectOnlyRoutes: true }));

const routes = {
  "GET /report": {
    accepts: {
      ...klerosX402PaymentOption({ network: "eip155:421614", token: { name: "USD Coin", version: "2" } }),
      payTo: merchant,
      price: { amount: "1500000", asset: usdc },
    },
  },
};
```

## Buyer

Created once, when the program starts, and used as `fetch` for every request from then on. The buyer chooses the signer, the folder for the payment records, the only token it pays with, the most it authorizes per payment, and optionally the longest an authorization may stay collectable, 300 seconds by default.

On a 402 the SDK pays the first offer into our operator that fits those limits and refuses anything else, binds the payment to the 402 by signing with the agreement's hash as salt, and writes `agreement.json` and `receipt.json` under `dir/<paymentHash>/`. Keep the directory: the agreement is what the payer pins when disputing.

```ts
import { privateKeyToAccount } from "viem/accounts";
import { klerosX402Fetch } from "kleros-x402-sdk";

const fetch = klerosX402Fetch({
  account: privateKeyToAccount(privateKey),
  dir: "./payments",
  asset: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // the only token this buyer pays with
  maxAmount: 10_000_000n, // the most it authorizes per payment, in base units: 10 USDC
  // maxTimeoutSeconds: 300, // the longest an authorization may stay collectable; 300 when omitted
});

const response = await fetch("https://api.example/report");
```

## While the payment is in escrow

Created once from viem clients on the same chain, the wallet client only for the calls that send transactions, and kept for as long as the program runs. The client's calls, and who makes them:

- `payment(paymentHash)`, anyone: the payment's status, amounts, dispute window and stored `PaymentInfo`.
- `payerAccept(paymentHash)`, payer: releases the payment to the merchant before the window ends.
- `merchantRefund(paymentHash, newTotal)`, merchant: raises the total refunded to the payer; refunding everything settles the payment.
- `dispute({ paymentHash, disputedAmount, ...agreement })`, payer, while the window is open: pins the agreement, pays the arbitration cost, opens the Kleros dispute and returns the Court case. The agreement is checked against the payment's salt before pinning and again after reading it back through `cdn.kleros.link`.
  - `paymentHash`: the payment's key, from the buyer's `receipt.json`.
  - `disputedAmount`: what the payer claims back, clamped to what is still disputable.
  - The agreement, one of two forms:
    - `{ agreementDir, pin }` to pin it now: `agreementDir` is the buyer's payment folder, where `klerosX402Fetch` wrote it; `pin` is any `(file, name) => Promise<string>` that pins the file and returns `/ipfs/<cid>`, `<cid>` or `ipfs://<cid>`, from a party's own IPFS node, any pinning service, or `pinataPinner`, the one the SDK currently ships.
    - `{ agreementURI }` when it is already pinned. Or `""` for disputes without an agreement, and jurors then establish the offer from the evidence the payer submits through the Court.
- `captureIfUnchallenged(paymentHash)`, anyone: pays the merchant once the window closed without a dispute.
- `executeRuling(paymentHash)`, anyone: settles a ruling the arbitrator could not settle in its own transaction.
- `caseData(disputeID)`, anyone: what the Court shows for the case.
- `courtCaseUrl(disputeID)`: the case page.

```ts
import { klerosX402Client, pinataPinner } from "kleros-x402-sdk";

const kleros = klerosX402Client({ publicClient, walletClient });

await kleros.payment(paymentHash); // status, amounts, dispute window, stored PaymentInfo

// Payer, while the dispute window is open. Pins the agreement, pays the arbitration cost, returns the Court case.
const { disputeID, disputedAmount, agreementURI, courtUrl } = await kleros.dispute({
  paymentHash,
  disputedAmount: 1500000n,
  agreementDir: "./payments",
  pin: pinataPinner(process.env.PINATA_JWT!),
});

await kleros.payerAccept(paymentHash); // payer: release the payment to the merchant early
await kleros.merchantRefund(paymentHash, 500000n); // merchant: raise the total refunded to the payer; refunding everything settles
await kleros.captureIfUnchallenged(paymentHash); // anyone: dispute window closed without a dispute
await kleros.executeRuling(paymentHash); // anyone: settle a ruling the arbitrator could not settle in its own transaction
await kleros.caseData(disputeID); // what the Court shows for the case
```

