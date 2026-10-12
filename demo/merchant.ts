/**
 * Copied from x402 examples/typescript/servers/auth-capture/custom-escrow.ts at 7f2b2f1 (lib/x402). Edits:
 * Arbitrum Sepolia; the route's payment option comes from klerosX402PaymentOption instead of
 * CUSTOM_OPERATOR_ADDRESS; the scheme is registered collect-only, as our facilitator advertises no receiver authorizer.
 */
import { HTTPFacilitatorClient } from "@x402/core/server";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/server";
import {
  paymentMiddlewareFromHTTPServer,
  x402HTTPResourceServer,
  x402ResourceServer,
} from "@x402/express";
import { config } from "dotenv";
import express from "express";
import { getAddress } from "viem";
import { klerosX402PaymentOption } from "kleros-x402-sdk";

config();

const NETWORK = "eip155:421614" as const;
const PORT = 4021;

const payTo = process.env.EVM_ADDRESS?.trim();
const facilitatorUrl = process.env.FACILITATOR_URL?.trim();

if (!payTo || !/^0x[0-9a-fA-F]{40}$/.test(payTo)) {
  console.error("Missing or invalid EVM_ADDRESS (checksummed 20-byte hex, 0x-prefixed)");
  process.exit(1);
}

if (!facilitatorUrl) {
  console.error("Missing required FACILITATOR_URL environment variable");
  process.exit(1);
}

const payToAddress = getAddress(payTo) as `0x${string}`;
const option = klerosX402PaymentOption({ network: NETWORK, token: { name: "USD Coin", version: "2" } });

const facilitatorClient = new HTTPFacilitatorClient({ url: facilitatorUrl });
const scheme = new AuthCaptureEvmScheme({ collectOnlyRoutes: true });

const resourceServer = new x402ResourceServer(facilitatorClient).register(NETWORK, scheme);
const httpServer = new x402HTTPResourceServer(resourceServer, {
  "GET /weather": {
    accepts: {
      ...option,
      price: "$0.01",
      payTo: payToAddress,
    },
    description: "Weather data",
    mimeType: "application/json",
  },
});

const app = express();

/**
 * Starts the resource server for the custom escrow, deferred capture flow.
 */
async function main(): Promise<void> {
  await httpServer.initialize();

  app.use(paymentMiddlewareFromHTTPServer(httpServer, undefined, undefined, false));

  app.get("/weather", (_req, res) => {
    res.send({
      report: {
        weather: "sunny",
        temperature: 70,
        flow: "custom-escrow",
      },
    });
  });

  app.listen(PORT, () => {
    console.log(`Auth-capture server (custom-escrow) listening at http://localhost:${PORT}`);
    console.log("  GET /weather");
    console.log(`  Custom operator: ${option.extra.captureAuthorizer}`);
    console.log("  Collect-only: capture/void/refund run out of band on the operator contract.");
  });
}

main().catch(err => {
  console.error("Startup failed:", err);
  process.exit(1);
});
