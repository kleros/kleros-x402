/** Buys /weather through the SDK. The receipt and the agreement land in ./payments/<paymentHash>/. */
import { buy } from "./clients";

async function main(): Promise<void> {
  const { response, receipt } = await buy();
  console.log({ status: response.status, body: await response.text(), paymentHash: receipt.paymentHash });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
