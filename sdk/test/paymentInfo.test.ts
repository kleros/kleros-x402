import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { keccak256, toBytes, zeroAddress, type Address, type Hex } from "viem";
import { AUTH_CAPTURE_ESCROW_V1_1_ADDRESS, type AuthCapturePaymentInfo } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import { klerosX402PaymentOption } from "../src/merchant.ts";
import { deploymentFor } from "../src/deployments.ts";
import { evmChainId, paymentHash, payerAgnosticPaymentHash } from "../src/paymentInfo.ts";

const info: AuthCapturePaymentInfo = {
  operator: deploymentFor("eip155:421614").operator,
  payer: "0x1111111111111111111111111111111111111111",
  receiver: "0x3333333333333333333333333333333333333333",
  token: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
  maxAmount: "1500000",
  preApprovalExpiry: 1790000000,
  authorizationExpiry: 281474976710655,
  refundExpiry: 281474976710655,
  minFeeBps: 0,
  maxFeeBps: 0,
  feeReceiver: zeroAddress,
  salt: keccak256(toBytes("agreement")),
};
const escrow: Address = "0x4444444444444444444444444444444444444444";

test("the port matches the official client, using its payload as the oracle", async () => {
  const option = klerosX402PaymentOption({ network: "eip155:421614", token: { name: "USDC", version: "2" } });
  const requirements = {
    ...option,
    asset: info.token,
    amount: info.maxAmount,
    payTo: info.receiver,
    maxTimeoutSeconds: 300,
    extra: { ...option.extra, authCaptureEscrow: AUTH_CAPTURE_ESCROW_V1_1_ADDRESS },
  };
  const signer = { address: info.payer, signTypedData: async (): Promise<Hex> => `0x${"ab".repeat(65)}` };
  const { payload } = await new AuthCaptureEvmScheme(
    signer as unknown as ConstructorParameters<typeof AuthCaptureEvmScheme>[0],
  ).createPaymentPayload(2, requirements);
  const official = payload as { authorization: { validBefore: string; nonce: Hex }; salt: Hex };
  const ours = payerAgnosticPaymentHash(
    421614,
    { ...info, preApprovalExpiry: Number(official.authorization.validBefore), salt: official.salt },
    AUTH_CAPTURE_ESCROW_V1_1_ADDRESS,
  );
  assert.equal(ours, official.authorization.nonce);
});

test("the port matches the escrow's getHash formula, encoded independently with cast", (t) => {
  if (spawnSync("cast", ["--version"]).status !== 0) return t.skip("cast not installed");
  const typehash = keccak256(
    toBytes(
      "PaymentInfo(address operator,address payer,address receiver,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 minFeeBps,uint16 maxFeeBps,address feeReceiver,uint256 salt)",
    ),
  );
  const cast = (...args: string[]) => execFileSync("cast", args, { encoding: "utf8" }).trim();
  const encoded = cast(
    "abi-encode",
    "f(bytes32,address,address,address,address,uint120,uint48,uint48,uint48,uint16,uint16,address,uint256)",
    typehash, info.operator, info.payer, info.receiver, info.token, info.maxAmount,
    String(info.preApprovalExpiry), String(info.authorizationExpiry), String(info.refundExpiry),
    String(info.minFeeBps), String(info.maxFeeBps), info.feeReceiver, BigInt(info.salt).toString(),
  );
  const structHash = cast("keccak", encoded);
  const outer = cast("keccak", cast("abi-encode", "f(uint256,address,bytes32)", "421614", escrow, structHash));
  assert.equal(paymentHash(421614, info, escrow), outer);
});

test("the hash changes with the payer, the chain and the escrow", () => {
  assert.notEqual(payerAgnosticPaymentHash(421614, info, escrow), paymentHash(421614, info, escrow));
  assert.equal(payerAgnosticPaymentHash(421614, info, escrow), paymentHash(421614, { ...info, payer: zeroAddress }, escrow));
  assert.notEqual(paymentHash(421614, info, escrow), paymentHash(1, info, escrow));
  assert.notEqual(paymentHash(421614, info, escrow), paymentHash(421614, info, AUTH_CAPTURE_ESCROW_V1_1_ADDRESS));
});

test("only decimal eip155 networks are accepted", () => {
  assert.equal(evmChainId("eip155:421614"), 421614);
  assert.throws(() => evmChainId("eip155:0x2105"));
  assert.throws(() => evmChainId("solana:devnet"));
});
