import { test } from "node:test";
import assert from "node:assert/strict";
import { isAddress, isAddressEqual, zeroAddress } from "viem";
import { deploymentFor } from "../src/deployments.ts";

test("the test network entry holds real addresses and an unknown network fails loudly", () => {
  const { operator, authCaptureEscrow, tokenCollector, courtUrl } = deploymentFor("eip155:421614");
  for (const address of [operator, authCaptureEscrow, tokenCollector]) {
    assert.ok(isAddress(address, { strict: true }) && !isAddressEqual(address, zeroAddress), address);
  }
  assert.match(courtUrl, /^https:\/\/[^/]+$/, "a base URL without a path");
  assert.throws(() => deploymentFor("eip155:8453"), /no deployment on eip155:8453/);
});
