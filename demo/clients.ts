/** What the demo scripts share: the resource, the buyer's folder, the purchase and the operator client. */
import "dotenv/config";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { klerosX402Client, klerosX402Fetch, type KlerosX402Receipt } from "kleros-x402-sdk";
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";

export const RESOURCE = "http://localhost:4021/weather";
export const DIR = "./payments";

export const buyerKey = () => process.env.BUYER_PRIVATE_KEY as Hex;
export const merchantKey = () => process.env.MERCHANT_PRIVATE_KEY as Hex;

/** Buys the resource through the SDK; the receipt is the folder that appeared under DIR. */
export async function buy() {
  const fetch = klerosX402Fetch({
    account: privateKeyToAccount(buyerKey()),
    dir: DIR,
    asset: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // USDC on Arbitrum Sepolia
    maxAmount: 1_000_000n, // 1 USDC
  });
  const before = new Set(existsSync(DIR) ? readdirSync(DIR) : []);
  const response = await fetch(RESOURCE);
  const [paymentHash] = readdirSync(DIR).filter((name) => !before.has(name));
  const receipt: KlerosX402Receipt = JSON.parse(readFileSync(`${DIR}/${paymentHash}/receipt.json`, "utf8"));
  return { response, receipt };
}

/** The operator client signing with `key`, and the public client its transactions are awaited on. */
export function kleros(key: Hex) {
  const transport = http();
  const publicClient = createPublicClient({ chain: arbitrumSepolia, transport });
  const walletClient = createWalletClient({ account: privateKeyToAccount(key), chain: arbitrumSepolia, transport });
  return { publicClient, client: klerosX402Client({ publicClient, walletClient }) };
}
