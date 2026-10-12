/** Buys /weather through the SDK. The receipt and the agreement land in ./payments/<paymentHash>/. */
import "dotenv/config";
import { existsSync, readdirSync } from "node:fs";
import { klerosX402Fetch } from "kleros-x402-sdk";
import { privateKeyToAccount } from "viem/accounts";

const RESOURCE = "http://localhost:4021/weather";
const DIR = "./payments";

const fetch = klerosX402Fetch({
  account: privateKeyToAccount(process.env.BUYER_PRIVATE_KEY as `0x${string}`),
  dir: DIR,
  asset: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // USDC on Arbitrum Sepolia
  maxAmount: 1_000_000n, // 1 USDC
});

async function main(): Promise<void> {
  const before = new Set(existsSync(DIR) ? readdirSync(DIR) : []);
  const response = await fetch(RESOURCE);
  const [paymentHash] = readdirSync(DIR).filter((name) => !before.has(name));
  console.log({ status: response.status, body: await response.text(), paymentHash });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
