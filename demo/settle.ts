/** The calls on the operator while a payment is in escrow, from the command line. */
import { pinataPinner } from "kleros-x402-sdk";
import type { Hex } from "viem";
import { buyerKey, DIR, kleros, merchantKey } from "./clients";

const USAGE = `usage: npm run settle -- <action> <paymentHash> [amount]   amounts in the token's base units, 10000 = 0.01 USDC
  payment                   read the payment
  payerAccept               payer: release the payment to the merchant
  merchantRefund <amount>   merchant: raise the total refunded to <amount>
  dispute <amount>          payer: dispute <amount>, pinning the agreement from ./payments
  captureIfUnchallenged     anyone, once the window closed without a dispute
  executeRuling             anyone, for a ruling the arbitrator could not settle itself`;

const [action, paymentHash, amount] = process.argv.slice(2);
const hash = paymentHash as Hex;

type Client = ReturnType<typeof kleros>["client"];
const actions: Record<string, (client: Client) => Promise<unknown>> = {
  payment: (client) => client.payment(hash),
  payerAccept: (client) => client.payerAccept(hash),
  merchantRefund: (client) => client.merchantRefund(hash, BigInt(amount)),
  dispute: (client) =>
    client.dispute({ paymentHash: hash, disputedAmount: BigInt(amount), agreementDir: DIR, pin: pinataPinner(process.env.PINATA_JWT!) }),
  captureIfUnchallenged: (client) => client.captureIfUnchallenged(hash),
  executeRuling: (client) => client.executeRuling(hash),
};

const run = actions[action];
const needsAmount = action === "merchantRefund" || action === "dispute";
if (!run || !paymentHash || (needsAmount && !amount)) {
  console.error(USAGE);
  process.exit(1);
}

async function main(): Promise<void> {
  const { publicClient, client } = kleros(action === "merchantRefund" ? merchantKey() : buyerKey());
  const result = await run(client);
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
