import { isAddressEqual, zeroAddress, type Address } from "viem";

/** Where our contracts live on one network. Filled in after each deploy; a redeploy is a new SDK version. */
export interface KlerosX402Deployment {
  /** `KlerosCaptureAuthorizer`. */
  operator: Address;
  /** The `AuthCaptureEscrow` the operator was deployed against. */
  authCaptureEscrow: Address;
  /** The escrow's ERC-3009 token collector, the `to` of the buyer's authorization. */
  tokenCollector: Address;
  /** The Court frontend URL. */
  courtUrl: string;
}

const deployments: Record<string, KlerosX402Deployment> = {
  // Arbitrum Sepolia, the test network. The canonical escrow is not deployed there, so this is our own deployment of it.
  "eip155:421614": {
    operator: "0x729CeC589286515A9bF28Fcdf0e71D2f94fAf674",
    authCaptureEscrow: "0x3e1e17725899ce96AF5C95b9f95a9c74588cf622",
    tokenCollector: "0xE96E9f608fE62a8A8A29cf1B9BBAE33799DaF8e3",
    courtUrl: "https://v2-testnet.kleros.builders",
  },
};

/** The deployment for `network`, or undefined. */
export const findDeployment = (network: string): KlerosX402Deployment | undefined => deployments[network];

/** The deployment for `network`, failing loudly when there is none or it is still a placeholder. */
export function deploymentFor(network: string): KlerosX402Deployment {
  const deployment = findDeployment(network);
  if (!deployment) throw new Error(`Kleros x402 has no deployment on ${network}`);
  if (isAddressEqual(deployment.operator, zeroAddress)) throw new Error(`Kleros x402 is not deployed on ${network} yet`);
  return deployment;
}
