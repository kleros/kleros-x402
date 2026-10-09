import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, toBytes, verifyTypedData, zeroAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { AuthCaptureEip3009Payload } from "@x402/evm";
import {
  decodePaymentSignatureHeader,
  encodePaymentRequiredHeader,
  encodePaymentResponseHeader,
} from "@x402/core/http";
import type { PaymentRequired } from "@x402/core/types";
import { klerosX402PaymentOption } from "../src/merchant.ts";
import { deploymentFor } from "../src/deployments.ts";
import { paymentHash, payerAgnosticPaymentHash } from "../src/paymentInfo.ts";
import {
  createPayment,
  klerosX402Fetch,
  selectRequirements,
  type KlerosX402BuyerConfig,
  type KlerosX402Receipt,
} from "../src/buyer.ts";

// Anvil's second default key: public, never funded on a real network.
const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const { operator, authCaptureEscrow: escrow, tokenCollector: collector } = deploymentFor("eip155:421614");
const merchant = "0x3333333333333333333333333333333333333333";
const usdc = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
const config: KlerosX402BuyerConfig = { account, dir: mkdtempSync(join(tmpdir(), "kleros-x402-")), asset: usdc, maxAmount: 2_000_000n };
const option = klerosX402PaymentOption({ network: "eip155:421614", token: { name: "USDC", version: "2" } });
const offer = { ...option, asset: usdc, amount: "1500000", payTo: merchant, maxTimeoutSeconds: 300 };
const paymentRequired: PaymentRequired = {
  x402Version: 2,
  resource: { url: "https://api.example/report", description: "Weekly report", mimeType: "application/json" },
  accepts: [offer],
};

test("the payment carries the given salt and a signature the token would accept", async () => {
  const salt = keccak256(toBytes("agreement"));
  const before = Math.floor(Date.now() / 1000);
  const payment = await createPayment(config, paymentRequired, offer, salt);
  const payload = payment.payload.payload as AuthCaptureEip3009Payload;
  assert.equal(payload.salt, salt);
  assert.equal(payment.paymentInfo.salt, salt);
  assert.equal(payment.paymentInfo.operator, operator);
  assert.equal(payment.paymentInfo.maxAmount, "1500000");
  assert.equal(payment.paymentInfo.authorizationExpiry, 281474976710655);
  assert.equal(payload.authorization.to, collector);
  assert.equal(payload.authorization.value, "1500000");
  assert.ok(Number(payload.authorization.validBefore) >= before + 300);
  assert.equal(payload.authorization.nonce, payerAgnosticPaymentHash(421614, payment.paymentInfo, escrow));
  assert.equal(payment.paymentHash, paymentHash(421614, payment.paymentInfo, escrow));
  assert.equal(payment.payload.accepted, offer);
  const valid = await verifyTypedData({
    address: account.address,
    domain: { name: "USDC", version: "2", chainId: 421614, verifyingContract: usdc },
    types: {
      ReceiveWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    primaryType: "ReceiveWithAuthorization",
    message: {
      from: account.address,
      to: collector,
      value: 1500000n,
      validAfter: 0n,
      validBefore: BigInt(payload.authorization.validBefore),
      nonce: payload.authorization.nonce,
    },
    signature: payload.signature,
  });
  assert.equal(valid, true);
});

test("only a complete auth-capture offer into our operator and escrow over EIP-3009, salt unbound, is accepted", () => {
  const other = { ...offer, extra: { ...offer.extra, captureAuthorizer: merchant } };
  const otherEscrow = { ...offer, extra: { ...offer.extra, authCaptureEscrow: merchant } };
  const otherToken = { ...offer, asset: merchant };
  const tooLong = { ...offer, maxTimeoutSeconds: 301 };
  const noTimeout = { ...offer, maxTimeoutSeconds: undefined } as unknown as typeof offer;
  const stringTimeout = { ...offer, maxTimeoutSeconds: "300" } as unknown as typeof offer;
  const zeroTimeout = { ...offer, maxTimeoutSeconds: 0 };
  const noPayee = { ...offer, payTo: zeroAddress };
  const directFlow = { ...offer, extra: { ...offer.extra, paymentFlow: "authorization" } };
  const autoCapture = { ...offer, extra: { ...offer.extra, captureMode: "auto" } };
  const noDomain = { ...offer, extra: { ...offer.extra, name: "" } };
  const noDomainVersion = { ...offer, extra: { ...offer.extra, version: "" } };
  const overCap = { ...offer, amount: "2000001" };
  const hexAmount = { ...offer, amount: "0x10" };
  const junkAmount = { ...offer, amount: "1.5" };
  const noEscrow = { ...offer, extra: { ...offer.extra, authCaptureEscrow: undefined } };
  const junkEscrow = { ...offer, extra: { ...offer.extra, authCaptureEscrow: 7 } };
  const badAddress = { ...offer, extra: { ...offer.extra, captureAuthorizer: "0xnot" } };
  const permit2 = { ...offer, extra: { ...offer.extra, assetTransferMethod: "permit2" } };
  const delegated = { ...offer, extra: { ...offer.extra, operatorType: "delegated" } };
  const malformed = { ...offer, extra: { ...offer.extra, captureDeadline: "soon" } };
  const exact = { ...offer, scheme: "exact", extra: {} };
  const boundByPolicy = { ...offer, extra: { ...offer.extra, policy: merchant } };
  const boundByReceiver = { ...offer, extra: { ...offer.extra, receiverAuthorizer: merchant } };
  const unbound = { ...offer, extra: { ...offer.extra, policy: zeroAddress, receiverAuthorizer: zeroAddress } };
  assert.equal(selectRequirements(config, { ...paymentRequired, accepts: [exact, badAddress, other, permit2, offer] }), offer);
  assert.equal(selectRequirements(config, { ...paymentRequired, accepts: [unbound] }), unbound);
  assert.equal(selectRequirements({ ...config, maxTimeoutSeconds: 900 }, { ...paymentRequired, accepts: [tooLong] }), tooLong, "the buyer's own ceiling");
  for (const bad of [other, otherEscrow, otherToken, tooLong, noTimeout, stringTimeout, zeroTimeout, noPayee, directFlow, autoCapture, noDomain, noDomainVersion, overCap, hexAmount, junkAmount, noEscrow, junkEscrow, badAddress, permit2, delegated, malformed, exact, boundByPolicy, boundByReceiver]) {
    assert.throws(
      () => selectRequirements(config, { ...paymentRequired, accepts: [bad] }),
      /no auth-capture payment into the Kleros operator/,
    );
  }
});

test("the fetch wrapper writes the agreement, pays with its hash as salt, and keeps the receipt", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const header = encodePaymentRequiredHeader(paymentRequired);
  const transaction = `0x${"cd".repeat(32)}` as Hex;
  let paidWith: Hex | undefined;
  const fetch: typeof globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    const signature = request.headers.get("PAYMENT-SIGNATURE");
    if (!signature) return new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": header } });
    const payload = decodePaymentSignatureHeader(signature);
    assert.deepEqual(payload.accepted, offer);
    paidWith = (payload.payload as AuthCaptureEip3009Payload).salt;
    return new Response("the report", {
      status: 200,
      headers: {
        "PAYMENT-RESPONSE": encodePaymentResponseHeader({ success: true, transaction, network: "eip155:421614", payer: account.address }),
      },
    });
  };
  const response = await klerosX402Fetch({ ...config, dir, fetch })("https://api.example/report");
  assert.equal(await response.text(), "the report");

  const [paymentDir] = readdirSync(dir);
  const agreement = readFileSync(join(dir, paymentDir, "agreement.json"));
  const receipt = JSON.parse(readFileSync(join(dir, paymentDir, "receipt.json"), "utf8")) as KlerosX402Receipt;
  assert.equal(paidWith, keccak256(agreement));
  assert.equal(receipt.salt, keccak256(agreement));
  assert.equal(receipt.paymentHash, paymentDir);
  assert.equal(receipt.settlement?.transaction, transaction);
  assert.equal(receipt.paymentInfo.maxAmount, "1500000");
  assert.ok(agreement.toString("utf8").endsWith(Buffer.from(header, "base64").toString("utf8") + "}"), "header bytes verbatim");
});

test("a 402 without a usable PAYMENT-REQUIRED header is refused before anything is signed or written", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const respond = (headers: Record<string, string>) => async () => new Response("payment required", { status: 402, headers });
  await assert.rejects(klerosX402Fetch({ ...config, dir, fetch: respond({}) })("https://api.example/report"), /402 without a PAYMENT-REQUIRED header/);
  await assert.rejects(klerosX402Fetch({ ...config, dir, fetch: respond({ "PAYMENT-REQUIRED": "not base64!" }) })("https://api.example/report"), /Invalid payment required header/);
  assert.deepEqual(readdirSync(dir), []);
});

test("a request that already carries a payment, or a 402 of another x402 version, is never paid", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const header = encodePaymentRequiredHeader(paymentRequired);
  const respond = (h: string) => async () => new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": h } });
  await assert.rejects(
    klerosX402Fetch({ ...config, dir, fetch: respond(header) })("https://api.example/report", { headers: { "PAYMENT-SIGNATURE": "stale" } }),
    /Payment already attempted/,
  );
  const noAccepts = encodePaymentRequiredHeader({ ...paymentRequired, accepts: undefined } as unknown as PaymentRequired);
  await assert.rejects(klerosX402Fetch({ ...config, dir, fetch: respond(noAccepts) })("https://api.example/report"), /no accepts list/);
  const v1 = encodePaymentRequiredHeader({ ...paymentRequired, x402Version: 1 });
  await assert.rejects(klerosX402Fetch({ ...config, dir, fetch: respond(v1) })("https://api.example/report"), /Unsupported x402Version: 1/);
  assert.deepEqual(readdirSync(dir), []);
});

test("a paid request that fails or answers with a bad PAYMENT-RESPONSE still leaves a complete receipt", async () => {
  const header = encodePaymentRequiredHeader(paymentRequired);
  const paymentRequiredResponse = () => new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": header } });

  const dirA = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const dies: typeof globalThis.fetch = async (input, init) => {
    if (new Request(input, init).headers.has("PAYMENT-SIGNATURE")) throw new Error("connection reset");
    return paymentRequiredResponse();
  };
  await assert.rejects(klerosX402Fetch({ ...config, dir: dirA, fetch: dies })("https://api.example/report"), /connection reset/);
  const [hashA] = readdirSync(dirA);
  const receiptA = JSON.parse(readFileSync(join(dirA, hashA, "receipt.json"), "utf8")) as KlerosX402Receipt;
  assert.equal(receiptA.status, 0, "signed but never answered");
  assert.equal(receiptA.paymentHash, hashA);
  assert.ok(receiptA.payload, "the signed payload is kept");

  const dirB = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const junk: typeof globalThis.fetch = async (input, init) => {
    if (new Request(input, init).headers.has("PAYMENT-SIGNATURE")) return new Response("the report", { status: 200, headers: { "PAYMENT-RESPONSE": "!!!" } });
    return paymentRequiredResponse();
  };
  const response = await klerosX402Fetch({ ...config, dir: dirB, fetch: junk })("https://api.example/report");
  assert.equal(await response.text(), "the report");
  const [hashB] = readdirSync(dirB);
  const receiptB = JSON.parse(readFileSync(join(dirB, hashB, "receipt.json"), "utf8")) as KlerosX402Receipt;
  assert.equal(receiptB.status, 200);
  assert.equal(receiptB.paymentResponse, "!!!");
  assert.equal(receiptB.settlement, null);
});

test("a request body reaches the merchant on both requests, and the receipt names the URL", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const header = encodePaymentRequiredHeader(paymentRequired);
  const bodies: string[] = [];
  const fetch: typeof globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    bodies.push(await request.text());
    if (!request.headers.has("PAYMENT-SIGNATURE")) return new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": header } });
    return new Response("the report", { status: 200 });
  };
  await klerosX402Fetch({ ...config, dir, fetch })("https://api.example/report", { method: "POST", body: '{"week":40}' });
  assert.deepEqual(bodies, ['{"week":40}', '{"week":40}']);
  const [hash] = readdirSync(dir);
  const receipt = JSON.parse(readFileSync(join(dir, hash, "receipt.json"), "utf8")) as KlerosX402Receipt;
  assert.equal(receipt.requestUrl, "https://api.example/report");
});

test("a payment the merchant refuses is recorded as such and never paid again", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const header = encodePaymentRequiredHeader(paymentRequired);
  let calls = 0;
  const fetch: typeof globalThis.fetch = async () => {
    calls++;
    return new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": header } });
  };
  const response = await klerosX402Fetch({ ...config, dir, fetch })("https://api.example/report");
  assert.equal(response.status, 402);
  assert.equal(calls, 2);
  const [hash] = readdirSync(dir);
  const receipt = JSON.parse(readFileSync(join(dir, hash, "receipt.json"), "utf8")) as KlerosX402Receipt;
  assert.equal(receipt.status, 402);
  assert.equal(receipt.settlement, null);
});

test("payments in flight at the same time get their own folders", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const header = encodePaymentRequiredHeader(paymentRequired);
  const fetch: typeof globalThis.fetch = async (input, init) => {
    if (!new Request(input, init).headers.has("PAYMENT-SIGNATURE")) return new Response("payment required", { status: 402, headers: { "PAYMENT-REQUIRED": header } });
    return new Response("the report", { status: 200 });
  };
  const pay = klerosX402Fetch({ ...config, dir, fetch });
  await Promise.all([pay("https://api.example/report"), pay("https://api.example/report")]);
  const folders = readdirSync(dir);
  assert.equal(folders.length, 2);
  for (const hash of folders) {
    const receipt = JSON.parse(readFileSync(join(dir, hash, "receipt.json"), "utf8")) as KlerosX402Receipt;
    assert.equal(receipt.paymentHash, hash);
    assert.equal(receipt.salt, keccak256(readFileSync(join(dir, hash, "agreement.json"))));
  }
});

test("without a fetch in the config the global one is used", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const realFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = realFetch; });
  globalThis.fetch = async () => new Response("free", { status: 200 });
  const response = await klerosX402Fetch({ ...config, dir })("https://api.example/free");
  assert.equal(await response.text(), "free");
});

test("a response that is not a 402 passes through untouched", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  const fetch = async () => new Response("free", { status: 200 });
  const response = await klerosX402Fetch({ ...config, dir, fetch })("https://api.example/free");
  assert.equal(await response.text(), "free");
  assert.deepEqual(readdirSync(dir), []);
});
