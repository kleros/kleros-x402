import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveAuthCaptureDeployment } from "@x402/evm";

// The addresses in x402-arbitrum-sepolia-escrow.patch.
const ESCROW = "0x3e1e17725899ce96AF5C95b9f95a9c74588cf622";
const COLLECTOR = "0xE96E9f608fE62a8A8A29cf1B9BBAE33799DaF8e3";

test("the build knows our Arbitrum Sepolia escrow", () => {
  const deployment = resolveAuthCaptureDeployment(ESCROW);
  assert.equal(deployment?.escrow, ESCROW);
  assert.equal(deployment?.eip3009Collector, COLLECTOR);
  assert.equal(deployment?.version, "v1.1");
  assert.equal(resolveAuthCaptureDeployment("0x0000000000000000000000000000000000000001"), undefined);
});
