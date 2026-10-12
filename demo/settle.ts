/** The calls on the operator while a payment is in escrow, from the command line. */
import "dotenv/config";
import { klerosX402Client, pinataPinner } from "kleros-x402-sdk";
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";

const USAGE = `usage: npm run settle -- <action> <paymentHash> [amount]
  payment                   read the payment
  payerAccept               payer: release the payment to the merchant
  merchantRefund <amount>   merchant: raise the total refunded to <amount>
  dispute <amount>          payer: dispute <amount>, pinning the agreement from ./payments
  captureIfUnchallenged     anyone, once the window closed without a dispute
  executeRuling             anyone, for a ruling the arbitrator could not settle itself`;

const [action, paymentHash, amount] = process.argv.slice(2);
const key = action === "merchantRefund" ? process.env.MERCHANT_PRIVATE_KEY : process.env.BUYER_PRIVATE_KEY;
const publicClient = createPublicClient({ chain: arbitrumSepolia, transport: http() });
const kleros = klerosX402Client({
  publicClient,
  walletClient: createWalletClient({ account: privateKeyToAccount(key as Hex), chain: arbitrumSepolia, transport: http() }),
});

const hash = paymentHash as Hex;
const actions: Record<string, () => Promise<unknown>> = {
  payment: () => kleros.payment(hash),
  payerAccept: () => kleros.payerAccept(hash),
  merchantRefund: () => kleros.merchantRefund(hash, BigInt(amount)),
  dispute: () =>
    kleros.dispute({ paymentHash: hash, disputedAmount: BigInt(amount), agreementDir: "./payments", pin: pinataPinner(process.env.PINATA_JWT!) }),
  captureIfUnchallenged: () => kleros.captureIfUnchallenged(hash),
  executeRuling: () => kleros.executeRuling(hash),
};

const run = actions[action];
const needsAmount = action === "merchantRefund" || action === "dispute";
if (!run || !paymentHash || (needsAmount && !amount)) {
  console.error(USAGE);
  process.exit(1);
}
async function main(): Promise<void> {
  const result = await run();
  // The one-call writes return the transaction hash; wait for it and report its status.
  if (typeof result === "string") {
    const receipt = await publicClient.waitForTransactionReceipt({ hash: result as Hex });
    console.log(receipt.status, result);
  } else {
    console.log(result);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
