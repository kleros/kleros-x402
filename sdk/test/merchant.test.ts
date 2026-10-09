import { test } from "node:test";
import assert from "node:assert/strict";
import { zeroAddress, type Hex } from "viem";
import { AUTH_CAPTURE_ESCROW_V1_1_ADDRESS, isAuthCaptureExtra } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import type { PaymentRequirements } from "@x402/core/types";
import type { RouteConfig } from "@x402/core/server";
import { klerosX402PaymentOption } from "../src/merchant.ts";
import { deploymentFor } from "../src/deployments.ts";

const { operator, authCaptureEscrow: ourEscrow } = deploymentFor("eip155:421614");
const merchant = "0x3333333333333333333333333333333333333333";
const usdc = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
const option = klerosX402PaymentOption({ network: "eip155:421614", token: { name: "USDC", version: "2" } });

/** A signer that never touches a key: the tests only need the official client to accept the fields. */
const fakeSigner = {
  address: "0x1111111111111111111111111111111111111111",
  signTypedData: async (): Promise<Hex> => `0x${"ab".repeat(65)}`,
} as unknown as ConstructorParameters<typeof AuthCaptureEvmScheme>[0];

const requirements = (extra: Record<string, unknown>): PaymentRequirements => ({
  scheme: option.scheme,
  network: "eip155:421614",
  asset: usdc,
  amount: "1500000",
  payTo: merchant,
  maxTimeoutSeconds: 300,
  extra,
});

test("the deadlines are uint48 max and the fees are zero", () => {
  assert.equal(option.extra.captureDeadline, 2 ** 48 - 1);
  assert.equal(option.extra.refundDeadline, 2 ** 48 - 1);
  assert.equal(option.extra.feeRecipient, zeroAddress);
  assert.equal(option.extra.minFeeBps, 0);
  assert.equal(option.extra.maxFeeBps, 0);
});

test("the network and the token's EIP-712 domain pass through, and the extra passes x402's guard", () => {
  assert.equal(option.network, "eip155:421614");
  assert.equal(option.extra.name, "USDC");
  assert.equal(option.extra.version, "2");
  assert.equal(isAuthCaptureExtra(option.extra), true);
});

test("an empty token name or version fails at route declaration", () => {
  assert.throws(() => klerosX402PaymentOption({ network: "eip155:421614", token: { name: "", version: "2" } }), /token.name and token.version/);
  assert.throws(() => klerosX402PaymentOption({ network: "eip155:421614", token: { name: "USDC", version: "" } }), /token.name and token.version/);
});

test("a network without a deployment fails at route declaration", () => {
  assert.throws(
    () => klerosX402PaymentOption({ network: "eip155:8453", token: { name: "USDC", version: "2" } }),
    /no deployment on eip155:8453/,
  );
});

test("the operator is a collect-only custom operator with deferred capture, receiverAuthorizer zero", () => {
  assert.equal(option.extra.captureAuthorizer, operator);
  assert.equal(option.extra.authCaptureEscrow, ourEscrow);
  assert.equal(option.extra.operatorType, "custom");
  assert.equal(option.extra.paymentFlow, "escrow");
  assert.equal(option.extra.captureMode, "deferred");
  assert.equal(option.extra.assetTransferMethod, "eip3009");
  assert.equal(option.extra.receiverAuthorizer, zeroAddress, "collect-only on the official server");
  assert.equal("policy" in option.extra, false);
});

test("the option spreads into an x402 route's accepts entry", () => {
  const route: RouteConfig = {
    accepts: { ...option, network: "eip155:421614", payTo: merchant, price: { amount: "1500000", asset: usdc } },
  };
  assert.equal(Array.isArray(route.accepts) ? undefined : route.accepts.scheme, "auth-capture");
});

test("the fields satisfy the official client, checked against the canonical escrow", async () => {
  const before = Math.floor(Date.now() / 1000);
  const result = await new AuthCaptureEvmScheme(fakeSigner).createPaymentPayload(
    2,
    requirements({ ...option.extra, authCaptureEscrow: AUTH_CAPTURE_ESCROW_V1_1_ADDRESS }),
  );
  const payload = result.payload as { authorization: Record<string, string>; signature: Hex; salt: Hex; saltNonce?: Hex };
  assert.equal(payload.authorization.value, "1500000");
  assert.ok(Number(payload.authorization.validBefore) >= before + 300);
  assert.match(payload.salt, /^0x[0-9a-f]{64}$/);
  assert.equal(payload.saltNonce, undefined, "no salt binding: no receiverAuthorizer and no policy");
});

test("the official client rejects a non-canonical escrow, which is why the SDK ships its own buyer client", async () => {
  await assert.rejects(
    new AuthCaptureEvmScheme(fakeSigner).createPaymentPayload(2, requirements(option.extra)),
    /Invalid authCaptureEscrow/,
  );
});
