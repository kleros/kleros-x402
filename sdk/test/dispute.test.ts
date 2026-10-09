import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hexToBigInt, keccak256, stringToBytes } from "viem";
import {
  encodeAbiParameters,
  encodeEventTopics,
  zeroAddress,
  type Account,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { klerosCaptureAuthorizerAbi } from "../src/contractTypes.ts";
import { klerosX402Client, pinataPinner } from "../src/dispute.ts";
import { deploymentFor } from "../src/deployments.ts";

const { operator } = deploymentFor("eip155:421614");
const arbitrator = "0x6666666666666666666666666666666666666666";
const payer = "0x1111111111111111111111111111111111111111";
const merchant = "0x3333333333333333333333333333333333333333";
const usdc = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
const extraData = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [8n, 3n, 1n]);
const arbitrationCost = 30000000000000000n;
const paymentHash = `0x${"ab".repeat(32)}` as Hex;
const txHash = `0x${"cd".repeat(32)}` as Hex;
const agreement = '{"nonce":"0x01","paymentRequired":{"x402Version":2}}';
const paymentInfo = {
  operator,
  payer,
  receiver: merchant,
  token: usdc,
  maxAmount: 1500000n,
  preApprovalExpiry: 1790000000,
  authorizationExpiry: 281474976710655,
  refundExpiry: 281474976710655,
  minFeeBps: 0,
  maxFeeBps: 0,
  feeReceiver: zeroAddress,
  salt: hexToBigInt(keccak256(stringToBytes(agreement))),
};
const caseData = {
  paymentHash,
  payer,
  receiver: merchant,
  token: usdc,
  authorizedAmount: 1500000n,
  disputedAmount: 1000000n,
  lockedRefundAmount: 0n,
  disputeWindowEnd: 1790000000,
  status: 2,
  ruling: 0n,
  agreementURI: "/ipfs/QmTest/agreement.json",
  salt: paymentHash,
};

type Call = { address: string; functionName: string; args?: readonly unknown[]; value?: bigint };

/** Clients that answer like the deployed contracts would and record what was asked of them. */
function fakeClients(disputeID = 42n) {
  const reads: Call[] = [];
  const writes: Call[] = [];
  const publicClient = {
    chain: { id: 421614 },
    async readContract(call: Call) {
      reads.push(call);
      switch (call.functionName) {
        case "arbitrator":
          return arbitrator;
        case "arbitratorExtraData":
          return extraData;
        case "arbitrationCost":
          return arbitrationCost;
        case "payments":
          return [1, 1790000000, 1500000n, 0n, 0n, 0n, 0n, ""];
        case "getPaymentInfo":
          return paymentInfo;
        case "getCaseData":
          return caseData;
        default:
          throw new Error(`Unexpected read of ${call.functionName}`);
      }
    },
    async waitForTransactionReceipt() {
      return {
        status: "success",
        logs: [
          {
            address: operator,
            topics: encodeEventTopics({
              abi: klerosCaptureAuthorizerAbi,
              eventName: "DisputeOpened",
              args: { _paymentHash: paymentHash, _disputeID: disputeID },
            }),
            data: encodeAbiParameters([{ type: "uint120" }], [1000000n]),
          },
        ],
      };
    },
  };
  const walletClient = {
    chain: { id: 421614 },
    async writeContract(call: Call) {
      writes.push(call);
      return txHash;
    },
  };
  return {
    reads,
    writes,
    publicClient: publicClient as unknown as PublicClient<Transport, Chain>,
    walletClient: walletClient as unknown as WalletClient<Transport, Chain, Account>,
  };
}

/** Serves `bytes` as cdn.kleros.link would, for any `/ipfs/` path. */
function gatewayServing(t: { after: (fn: () => void) => void }, bytes: string | null) {
  const realFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = realFetch; });
  const seen: string[] = [];
  globalThis.fetch = async (input) => {
    seen.push(String(input));
    return bytes === null ? new Response("not found", { status: 404 }) : new Response(bytes);
  };
  return seen;
}

test("dispute pins the agreement, reads it back through the Court's gateway, pays the arbitration cost, and reports the dispute from the mined event", async (t) => {
  const { reads, writes, publicClient, walletClient } = fakeClients();
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  mkdirSync(join(dir, paymentHash));
  writeFileSync(join(dir, paymentHash, "agreement.json"), agreement);
  const gateway = gatewayServing(t, agreement);
  const pinned: { file: string; name: string }[] = [];
  const pin = async (file: Uint8Array, name: string) => {
    pinned.push({ file: Buffer.from(file).toString("utf8"), name });
    return `/ipfs/QmTest/${name}`;
  };

  const result = await klerosX402Client({ publicClient, walletClient }).dispute({
    paymentHash,
    disputedAmount: 1000000n,
    agreementDir: dir,
    pin,
  });

  assert.deepEqual(pinned, [{ file: agreement, name: "agreement.json" }]);
  assert.deepEqual(gateway, ["https://cdn.kleros.link/ipfs/QmTest/agreement.json"], "read back the way jurors will");
  for (const bad of ["../../etc/passwd", "0x1234", "", paymentHash.slice(0, -2)]) {
    await assert.rejects(
      klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash: bad as Hex, disputedAmount: 1n, agreementDir: dir, pin }),
      /Not a payment hash/,
    );
  }
  assert.equal(pinned.length, 1, "nothing else was pinned");
  assert.deepEqual(
    reads.map((r) => [r.address, r.functionName, r.args]),
    [
      [operator, "getPaymentInfo", [paymentHash]],
      [operator, "arbitrator", undefined],
      [operator, "arbitratorExtraData", undefined],
      [arbitrator, "arbitrationCost", [extraData]],
    ],
  );
  assert.equal(writes.length, 1);
  assert.equal(writes[0].address, operator);
  assert.equal(writes[0].functionName, "dispute");
  assert.deepEqual(writes[0].args, [paymentHash, 1000000n, "/ipfs/QmTest/agreement.json"]);
  assert.equal(writes[0].value, arbitrationCost);
  assert.deepEqual(result, {
    hash: txHash,
    disputeID: 42n,
    disputedAmount: 1000000n,
    agreementURI: "/ipfs/QmTest/agreement.json",
    courtUrl: "https://v2-testnet.kleros.builders/#/cases/42/overview",
  });
});

test("a dispute with an agreement URI in hand pins nothing and needs no local file, but the pinned file must hash to the salt", async (t) => {
  const { writes, publicClient, walletClient } = fakeClients(7n);
  const gateway = gatewayServing(t, agreement);
  const result = await klerosX402Client({ publicClient, walletClient }).dispute({
    paymentHash,
    disputedAmount: 1n,
    agreementURI: "/ipfs/QmElsewhere/agreement.json",
  });
  assert.deepEqual(gateway, ["https://cdn.kleros.link/ipfs/QmElsewhere/agreement.json"]);
  assert.deepEqual(writes[0].args, [paymentHash, 1n, "/ipfs/QmElsewhere/agreement.json"]);
  assert.equal(result.disputeID, 7n);
});

test("a pinned file that does not hash to the payment's salt never reaches the chain", async (t) => {
  const { reads, writes, publicClient, walletClient } = fakeClients();
  gatewayServing(t, agreement + "\n");
  await assert.rejects(
    klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: "/ipfs/QmWrong/agreement.json" }),
    /does not hash to the payment's salt/,
  );
  assert.deepEqual(reads.map((r) => r.functionName), ["getPaymentInfo"]);
  assert.deepEqual(writes, []);
});

test("an empty agreement URI disputes without an agreement: nothing is read, fetched or pinned", async (t) => {
  const { reads, writes, publicClient, walletClient } = fakeClients(9n);
  const gateway = gatewayServing(t, null);
  const result = await klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: "" });
  assert.deepEqual(gateway, []);
  assert.deepEqual(reads.map((r) => r.functionName), ["arbitrator", "arbitratorExtraData", "arbitrationCost"]);
  assert.deepEqual(writes[0].args, [paymentHash, 1n, ""]);
  assert.equal(result.disputeID, 9n);
});

test("a CID, an ipfs:// URI or an /ipfs/ path all become the /ipfs/<cid> the Court resolves; anything else is refused before any read", async (t) => {
  const { writes, publicClient, walletClient } = fakeClients();
  const gateway = gatewayServing(t, agreement);
  for (const uri of ["QmBare/agreement.json", "ipfs://QmBare/agreement.json", "/ipfs/QmBare/agreement.json"]) {
    const result = await klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: uri });
    assert.equal(result.agreementURI, "/ipfs/QmBare/agreement.json");
  }
  assert.deepEqual(writes.map((w) => w.args?.[2]), Array(3).fill("/ipfs/QmBare/agreement.json"));
  assert.deepEqual(gateway, Array(3).fill("https://cdn.kleros.link/ipfs/QmBare/agreement.json"));
  for (const uri of ["https://cdn.kleros.link/ipfs/QmBare", "/ipfs/", "/ipfs/Qm Bare", "ipfs://"]) {
    await assert.rejects(
      klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: uri }),
      /Not an IPFS URI/,
    );
  }
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  mkdirSync(join(dir, paymentHash));
  writeFileSync(join(dir, paymentHash, "agreement.json"), agreement);
  const pinned = await klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementDir: dir, pin: async () => "QmFromPinner" });
  assert.equal(pinned.agreementURI, "/ipfs/QmFromPinner");
  assert.equal(gateway.length, 4);
  assert.equal(writes.length, 4);
});

test("a local agreement that was altered after payment is neither pinned nor disputed", async (t) => {
  const { writes, publicClient, walletClient } = fakeClients();
  const dir = mkdtempSync(join(tmpdir(), "kleros-x402-"));
  mkdirSync(join(dir, paymentHash));
  writeFileSync(join(dir, paymentHash, "agreement.json"), agreement + "\n");
  const gateway = gatewayServing(t, agreement + "\n");
  let pins = 0;
  await assert.rejects(
    klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementDir: dir, pin: async () => { pins++; return "/ipfs/QmX"; } }),
    /local agreement does not hash to the payment's salt/,
  );
  assert.equal(pins, 0);
  assert.deepEqual(gateway, []);
  assert.deepEqual(writes, []);
});

test("a reverted dispute transaction is reported as such", async (t) => {
  const { publicClient, walletClient } = fakeClients();
  (publicClient as unknown as { waitForTransactionReceipt: () => Promise<unknown> }).waitForTransactionReceipt = async () => ({ status: "reverted", logs: [] });
  gatewayServing(t, agreement);
  await assert.rejects(
    klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: "/ipfs/QmTest/agreement.json" }),
    /reverted/,
  );
});

test("a mined transaction without our contract's DisputeOpened is not reported as a dispute", async (t) => {
  const { publicClient, walletClient } = fakeClients();
  const original = publicClient.waitForTransactionReceipt;
  (publicClient as unknown as { waitForTransactionReceipt: typeof original }).waitForTransactionReceipt = (async (args: unknown) => {
    const receipt = await original(args as Parameters<typeof original>[0]);
    return { ...receipt, logs: receipt.logs.map((log) => ({ ...log, address: merchant })) }; // same event, another contract
  }) as typeof original;
  gatewayServing(t, agreement);
  await assert.rejects(
    klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: "/ipfs/QmTest/agreement.json" }),
    /did not open a dispute/,
  );
});

test("a pinned file the gateway never serves is given up on after a minute, with the last status reported", async (t) => {
  const { reads, writes, publicClient, walletClient } = fakeClients();
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const gateway = gatewayServing(t, null);
  const attempt = klerosX402Client({ publicClient, walletClient }).dispute({ paymentHash, disputedAmount: 1n, agreementURI: "/ipfs/QmNever/agreement.json" });
  const outcome = attempt.then(() => "resolved", (error: Error) => error.message);
  for (let i = 0; i < 25; i++) {
    await new Promise((resolve) => setImmediate(resolve)); // let the pending fetch settle before advancing the clock
    t.mock.timers.tick(3000);
  }
  assert.match(await outcome, /not readable through https:\/\/cdn\.kleros\.link within 60 s \(status 404\)/);
  assert.ok(gateway.length >= 20, `retried ${gateway.length} times`);
  assert.deepEqual(reads.map((r) => r.functionName), ["getPaymentInfo"]);
  assert.deepEqual(writes, []);
});

test("a wallet client on another chain than the public client is refused up front", () => {
  const { publicClient, walletClient } = fakeClients();
  const elsewhere = { ...walletClient, chain: { id: 1 } } as unknown as typeof walletClient;
  assert.throws(() => klerosX402Client({ publicClient, walletClient: elsewhere }), /chain 1, publicClient on 421614/);
});

test("payment and caseData read the contract and name the status", async () => {
  const { reads, publicClient } = fakeClients();
  const kleros = klerosX402Client({ publicClient });
  const payment = await kleros.payment(paymentHash);
  assert.deepEqual(payment, {
    status: "Authorized",
    disputeWindowEnd: 1790000000,
    authorizedAmount: 1500000n,
    disputedAmount: 0n,
    lockedRefundAmount: 0n,
    disputeID: 0n,
    ruling: 0n,
    agreementURI: "",
    paymentInfo,
  });
  assert.deepEqual(await kleros.caseData(42n), { ...caseData, status: "Disputed" });
  assert.deepEqual(
    reads.map((r) => [r.functionName, r.args]),
    [
      ["payments", [paymentHash]],
      ["getPaymentInfo", [paymentHash]],
      ["getCaseData", [42n]],
    ],
  );
});

test("the write calls carry the contract's names and arguments", async () => {
  const { writes, publicClient, walletClient } = fakeClients();
  const kleros = klerosX402Client({ publicClient, walletClient });
  assert.equal(await kleros.payerAccept(paymentHash), txHash);
  await kleros.merchantRefund(paymentHash, 500000n);
  await kleros.captureIfUnchallenged(paymentHash);
  await kleros.executeRuling(paymentHash);
  assert.deepEqual(
    writes.map((w) => [w.address, w.functionName, w.args, w.value]),
    [
      [operator, "payerAccept", [paymentHash], undefined],
      [operator, "merchantRefund", [paymentHash, 500000n], undefined],
      [operator, "captureIfUnchallenged", [paymentHash], undefined],
      [operator, "executeRuling", [paymentHash], undefined],
    ],
  );
});

test("sending without a wallet client fails before anything is read", async () => {
  const { reads, publicClient } = fakeClients();
  const kleros = klerosX402Client({ publicClient });
  await assert.rejects(kleros.payerAccept(paymentHash), /walletClient/);
  await assert.rejects(kleros.dispute({ paymentHash, disputedAmount: 1n, agreementURI: "" }), /walletClient/);
  assert.deepEqual(reads, []);
});

test("the case URL is the deployment's Court front end", () => {
  const { publicClient } = fakeClients();
  assert.equal(klerosX402Client({ publicClient }).courtCaseUrl(7n), "https://v2-testnet.kleros.builders/#/cases/7/overview");
});

test("pinataPinner uploads the file as a public multipart upload and returns its IPFS path", async (t) => {
  let seen: { url: string; method?: string; headers: Record<string, string>; body: FormData } | undefined;
  const realFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = realFetch; });
  globalThis.fetch = async (input, init) => {
    seen = { url: String(input), method: init?.method, headers: init?.headers as Record<string, string>, body: init?.body as FormData };
    return new Response(JSON.stringify({ data: { id: "1", cid: "bafybeiagreement", name: "agreement.json" } }));
  };
  const uri = await pinataPinner("jwt-token")(Buffer.from('{"nonce":"0x01"}', "utf8"), "agreement.json");
  assert.equal(uri, "/ipfs/bafybeiagreement");
  assert.equal(seen?.url, "https://uploads.pinata.cloud/v3/files");
  assert.equal(seen?.method, "POST");
  assert.equal(seen?.headers.Authorization, "Bearer jwt-token");
  assert.equal(seen?.body.get("network"), "public");
  const file = seen?.body.get("file");
  assert.ok(file instanceof File);
  assert.equal(file.name, "agreement.json");
  assert.equal(await file.text(), '{"nonce":"0x01"}');
  globalThis.fetch = async () => new Response("nope", { status: 401 });
  await assert.rejects(pinataPinner("jwt-token")(Buffer.from("x"), "agreement.json"), /status 401/);
  for (const body of ["{}", '{"data":{}}', '{"data":{"cid":""}}', '{"data":{"cid":7}}']) {
    globalThis.fetch = async () => new Response(body);
    await assert.rejects(pinataPinner("jwt-token")(Buffer.from("x"), "agreement.json"), /no CID/);
  }
});
