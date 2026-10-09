import { zeroAddress } from "viem";
import { AUTH_CAPTURE_SCHEME, type AuthCaptureExtra } from "@x402/evm";
import type { Network } from "@x402/core/types";
import { deploymentFor } from "./deployments.ts";

/**
 * Capture and refund deadline in the 402: uint48 max, so no ruling can arrive too late. The escrow sets
 * no maximum; the KlerosCA rejects deadlines shorter than its dispute window plus buffer.
 */
const NO_EXPIRY = 281474976710655;

export interface KlerosX402MerchantConfig {
  /** The route's network, e.g. `eip155:421614`. Picks our deployment. */
  network: Network;
  /** EIP-712 domain of the payment token, which buyers sign under. Read it from the token. */
  token: { name: string; version: string };
}

/** A mapped type, not `AuthCaptureExtra` itself: an interface is not assignable to `PaymentOption.extra`, a `Record<string, unknown>`. */
export type KlerosX402PaymentOption = {
  scheme: typeof AUTH_CAPTURE_SCHEME;
  network: Network;
  extra: Required<Omit<AuthCaptureExtra, "policy">>;
};

/**
 * The auth-capture part of a route's payment option, to spread next to `payTo` and `price`.
 * Collect-only custom operator: the facilitator relays `authorize` only, our contract settles later; no fees.
 */
export function klerosX402PaymentOption(config: KlerosX402MerchantConfig): KlerosX402PaymentOption {
  const { operator, authCaptureEscrow } = deploymentFor(config.network);
  // An empty name or version makes every buyer signature invalid.
  if (!config.token.name || !config.token.version) throw new Error("token.name and token.version are required");
  return {
    scheme: AUTH_CAPTURE_SCHEME,
    network: config.network,
    extra: {
      name: config.token.name,
      version: config.token.version,
      authCaptureEscrow,
      captureAuthorizer: operator,
      operatorType: "custom",
      paymentFlow: "escrow",
      captureMode: "deferred",
      assetTransferMethod: "eip3009",
      // Zero = collect-only, nobody signs captures. Omitted, the merchant server fills in the facilitator's key or throws.
      receiverAuthorizer: zeroAddress,
      captureDeadline: NO_EXPIRY,
      refundDeadline: NO_EXPIRY,
      feeRecipient: zeroAddress,
      minFeeBps: 0,
      maxFeeBps: 0,
    },
  };
}
