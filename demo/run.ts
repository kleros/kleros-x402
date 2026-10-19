/** One demo scenario per call: a purchase, then its settlement path. */
import { pinataPinner } from "kleros-x402-sdk";
import type { Hex } from "viem";
import { buy, buyerKey, DIR, kleros, merchantKey } from "./clients";

const USAGE = `usage: npm run demo -- <scenario>
  capture   pay, wait for the dispute window to close, captureIfUnchallenged
  release   pay, payerAccept
  refund    pay, merchantRefund of the full amount
  dispute   pay, dispute the full amount
  partial   pay, dispute half the amount`;

const [scenario] = process.argv.slice(2);
if (!["capture", "release", "refund", "dispute", "partial"].includes(scenario)) {
  console.error(USAGE);
  process.exit(1);
}

async function main(): Promise<void> {
  const { response, receipt } = await buy();
  if (response.status !== 200) throw new Error(`Payment refused: ${response.status} ${JSON.stringify(receipt.settlement)}`);
  const paymentHash = receipt.paymentHash;
  const amount = BigInt(receipt.paymentInfo.maxAmount);
  console.log({ scenario, paymentHash, authorizeTx: receipt.settlement?.transaction });

  const { publicClient, client } = kleros(scenario === "refund" ? merchantKey() : buyerKey());
  const report = async (action: string, tx: Hex) => {
    const { status } = await publicClient.waitForTransactionReceipt({ hash: tx });
    console.log({ action, tx, status });
  };

  switch (scenario) {
    case "release":
      return report("payerAccept", await client.payerAccept(paymentHash));
    case "refund":
      return report("merchantRefund", await client.merchantRefund(paymentHash, amount));
    case "dispute":
    case "partial": {
      const disputedAmount = scenario === "dispute" ? amount : amount / 2n;
      const opened = await client.dispute({ paymentHash, disputedAmount, agreementDir: DIR, pin: pinataPinner(process.env.PINATA_JWT!) });
      console.log({ action: "dispute", tx: opened.hash, disputeID: opened.disputeID, disputedAmount: opened.disputedAmount, agreementURI: opened.agreementURI, courtUrl: opened.courtUrl });
      return;
    }
    case "capture": {
      const { disputeWindowEnd } = await client.payment(paymentHash);
      const closesAt = new Date(Number(disputeWindowEnd) * 1000);
      console.log(`window closes at ${closesAt.toISOString()}, waiting`);
      await new Promise((resolve) => setTimeout(resolve, Math.max(0, closesAt.getTime() + 15_000 - Date.now()))); // 15 s over the block clock
      return report("captureIfUnchallenged", await client.captureIfUnchallenged(paymentHash));
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
