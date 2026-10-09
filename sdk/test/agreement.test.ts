import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decodePaymentRequiredHeader, encodePaymentRequiredHeader } from "@x402/core/http";
import type { PaymentRequired } from "@x402/core/types";
import { buildAgreementFile } from "../src/agreement.ts";

const paymentRequired: PaymentRequired = {
  x402Version: 2,
  resource: { url: "https://api.example/report", description: "Weekly report", mimeType: "application/json" },
  accepts: [
    {
      scheme: "auth-capture",
      network: "eip155:421614",
      asset: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
      amount: "1500000",
      payTo: "0x3333333333333333333333333333333333333333",
      maxTimeoutSeconds: 300,
      extra: { operatorType: "custom", captureAuthorizer: "0x2222222222222222222222222222222222222222" },
    },
  ],
};
const header = encodePaymentRequiredHeader(paymentRequired);
const bytes = Buffer.from(header, "base64");
const FILE_SHAPE = /^\{"nonce":"(0x[0-9a-f]{64})","paymentRequired":(.*)\}$/s;

test("the file is one line: a 32-byte nonce, then the header bytes verbatim, odd formatting and non-ASCII included", () => {
  for (const odd of ['{"x402Version":2,  "accepts":[] ,\n"resource":{"url":"u"}}', '{"resource":{"description":"Café — 日本語 \u00e9"}}']) {
    const file = buildAgreementFile(Buffer.from(odd, "utf8"));
    const text = Buffer.from(file.bytes).toString("utf8");
    const parts = FILE_SHAPE.exec(text);
    assert.ok(parts, "file shape");
    assert.equal(parts[2], odd);
    assert.ok(Buffer.from(file.bytes).subarray(-1 - Buffer.byteLength(odd)).subarray(0, -1).equals(Buffer.from(odd, "utf8")), "bytes, not just text, verbatim");
    assert.equal(text.indexOf("\n", 1 + text.indexOf('"paymentRequired":') + odd.length), -1, "nothing after the inserted bytes");
  }
});

test("the hash matches cast keccak on the written file", (t) => {
  if (spawnSync("cast", ["--version"]).status !== 0) return t.skip("cast not installed");
  const file = buildAgreementFile(bytes);
  const dir = mkdtempSync(join(tmpdir(), "agreement-"));
  const path = join(dir, "agreement.json");
  writeFileSync(path, file.bytes);
  const cast = execFileSync("sh", ["-c", `cast keccak < "${path}"`], { encoding: "utf8" }).trim();
  assert.equal(cast, file.hash);
});

test("the nonce makes repeat purchases of the same offer distinct", () => {
  assert.notEqual(buildAgreementFile(bytes).hash, buildAgreementFile(bytes).hash);
});

test("the file parses back to what @x402/core decodes from the header", () => {
  const parsed = JSON.parse(Buffer.from(buildAgreementFile(bytes).bytes).toString("utf8"));
  assert.deepEqual(parsed.paymentRequired, decodePaymentRequiredHeader(header));
  assert.match(parsed.nonce, /^0x[0-9a-f]{64}$/);
});
