import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { getAddress, isAddress, isAddressEqual, zeroAddress, type Address, type Hex } from "viem";
import {
  AUTH_CAPTURE_SCHEME,
  authorizationTypes,
  isAuthCaptureExtra,
  type AuthCaptureEip3009Payload,
  type AuthCaptureExtra,
  type AuthCapturePaymentInfo,
  type ClientEvmSigner,
} from "@x402/evm";
import { decodePaymentRequiredHeader, decodePaymentResponseHeader, encodePaymentSignatureHeader } from "@x402/core/http";
import type { PaymentPayload, PaymentRequired, PaymentRequirements, SettleResponse } from "@x402/core/types";
import { AGREEMENT_FILE_NAME, buildAgreementFile } from "./agreement.ts";
import { evmChainId, paymentHash, payerAgnosticPaymentHash } from "./paymentInfo.ts";
import { deploymentFor, findDeployment } from "./deployments.ts";

const PAYMENT_REQUIRED_HEADER = "PAYMENT-REQUIRED";
const PAYMENT_SIGNATURE_HEADER = "PAYMENT-SIGNATURE";
const PAYMENT_RESPONSE_HEADER = "PAYMENT-RESPONSE";
const RECEIPT_FILE_NAME = "receipt.json";
/** The merchant server's default `maxTimeoutSeconds`; x402 keeps the number inline. */
const DEFAULT_MAX_TIMEOUT_SECONDS = 300;

export interface KlerosX402BuyerConfig {
  /** Signs the ERC-3009 authorization: any x402 client signer, typically a viem local account. */
  account: ClientEvmSigner;
  /** Where `<paymentHash>/agreement.json` and `receipt.json` are written for every payment. */
  dir: string;
  /** The only token this buyer pays with. */
  asset: Address;
  /** The most this buyer authorizes per payment, in the token's base units. A 402 asking for more is refused. */
  maxAmount: bigint;
  /** Longest collection window this buyer accepts, in seconds. The 402 carries the merchant's; more is refused. Default 300. */
  maxTimeoutSeconds?: number;
  /** Defaults to the global `fetch`. */
  fetch?: typeof globalThis.fetch;
}

type KlerosX402Offer = PaymentRequirements & { extra: AuthCaptureExtra };

/** x402's unexported `isNonZeroAddress`: set means present, valid and not zero. */
const isNonZeroAddress = (value: string | undefined): value is Address =>
  !!value && isAddress(value) && !isAddressEqual(value, zeroAddress);

/** Decimal integer within the cap. `BigInt` alone would accept hex and throw on junk. */
const withinCap = (amount: string, cap: bigint) => /^\d+$/.test(amount) && BigInt(amount) <= cap;

/** The buyer's limits: his token, his cap, his collection window, a real payee. */
function withinBuyerLimits(config: KlerosX402BuyerConfig, r: PaymentRequirements): boolean {
  return (
    // The type says string; the decoded 402 may say otherwise. Skip such an entry, do not throw.
    String(r.asset).toLowerCase() === config.asset.toLowerCase() &&
    withinCap(String(r.amount), config.maxAmount) &&
    typeof r.maxTimeoutSeconds === "number" &&
    r.maxTimeoutSeconds > 0 &&
    r.maxTimeoutSeconds <= (config.maxTimeoutSeconds ?? DEFAULT_MAX_TIMEOUT_SECONDS) &&
    isNonZeroAddress(r.payTo)
  );
}

/** Auth-capture, `extra` of x402's shape, a token domain to sign under. */
function isAuthCaptureOffer(r: PaymentRequirements): r is KlerosX402Offer {
  return r.scheme === AUTH_CAPTURE_SCHEME && isAuthCaptureExtra(r.extra) && r.extra.name !== "" && r.extra.version !== "";
}

/**
 * Our operator and the escrow it was deployed against, custom operator, EIP-3009 (the x402 default when absent),
 * escrow flow with deferred capture (our contract reverts `charge`), salt binding off (our salt is the agreement hash).
 */
function intoKlerosX402Deployment(r: KlerosX402Offer): boolean {
  const { extra } = r;
  const deployment = findDeployment(r.network);
  return (
    deployment !== undefined &&
    extra.operatorType === "custom" &&
    (extra.assetTransferMethod ?? "eip3009") === "eip3009" &&
    extra.paymentFlow === "escrow" &&
    extra.captureMode === "deferred" &&
    extra.captureAuthorizer.toLowerCase() === deployment.operator.toLowerCase() &&
    String(extra.authCaptureEscrow).toLowerCase() === deployment.authCaptureEscrow.toLowerCase() &&
    !isNonZeroAddress(extra.receiverAuthorizer) &&
    !isNonZeroAddress(extra.policy)
  );
}

/** The offer this buyer is willing to pay. */
function acceptable(config: KlerosX402BuyerConfig, r: PaymentRequirements): r is KlerosX402Offer {
  return withinBuyerLimits(config, r) && isAuthCaptureOffer(r) && intoKlerosX402Deployment(r);
}

export function selectRequirements(config: KlerosX402BuyerConfig, paymentRequired: PaymentRequired): KlerosX402Offer {
  if (!Array.isArray(paymentRequired.accepts)) throw new Error("The 402 has no accepts list");
  const match = paymentRequired.accepts.find((r) => acceptable(config, r));
  if (!match) throw new Error("The 402 offers no auth-capture payment into the Kleros operator in the buyer's token within his cap");
  return match;
}

export interface KlerosX402Payment {
  paymentInfo: AuthCapturePaymentInfo;
  /** The escrow's key for this payment, what every operator call takes. */
  paymentHash: Hex;
  payload: PaymentPayload;
}

/** Signs the payment with `salt` as `PaymentInfo.salt`; the fetch wrapper passes the agreement hash. */
export async function createPayment(
  config: KlerosX402BuyerConfig,
  paymentRequired: PaymentRequired,
  requirements: KlerosX402Offer,
  salt: Hex,
): Promise<KlerosX402Payment> {
  const { extra } = requirements;
  const { authCaptureEscrow, tokenCollector } = deploymentFor(requirements.network);
  const chainId = evmChainId(requirements.network);
  const preApprovalExpiry = Math.floor(Date.now() / 1000) + requirements.maxTimeoutSeconds;
  const paymentInfo: AuthCapturePaymentInfo = {
    operator: getAddress(extra.captureAuthorizer),
    payer: config.account.address,
    receiver: getAddress(requirements.payTo),
    token: getAddress(requirements.asset),
    maxAmount: requirements.amount,
    preApprovalExpiry,
    authorizationExpiry: extra.captureDeadline,
    refundExpiry: extra.refundDeadline,
    minFeeBps: extra.minFeeBps,
    maxFeeBps: extra.maxFeeBps,
    feeReceiver: getAddress(extra.feeRecipient),
    salt,
  };
  const nonce = payerAgnosticPaymentHash(chainId, paymentInfo, authCaptureEscrow);
  const authorization = {
    from: paymentInfo.payer,
    to: tokenCollector,
    value: paymentInfo.maxAmount,
    validAfter: "0",
    validBefore: String(preApprovalExpiry),
    nonce,
  };
  const signature = await config.account.signTypedData({
    domain: { name: extra.name, version: extra.version, chainId, verifyingContract: paymentInfo.token },
    // ERC-3009 gives both structs the same fields; x402 exports only the transfer one.
    types: { ReceiveWithAuthorization: authorizationTypes.TransferWithAuthorization },
    primaryType: "ReceiveWithAuthorization",
    message: { ...authorization, value: BigInt(authorization.value), validAfter: 0n, validBefore: BigInt(preApprovalExpiry) },
  });
  const payload: AuthCaptureEip3009Payload = { authorization, signature, salt };
  return {
    paymentInfo,
    paymentHash: paymentHash(chainId, paymentInfo, authCaptureEscrow),
    payload: { x402Version: 2, resource: paymentRequired.resource, accepted: requirements, payload },
  };
}

/** The buyer's record of one payment, `receipt.json` next to the agreement. */
export interface KlerosX402Receipt {
  /** The URL that was paid for. */
  requestUrl: string;
  /** The payment's key on chain, and the folder name. */
  paymentHash: Hex;
  /** `PaymentInfo.salt`: the keccak256 of the agreement file. */
  salt: Hex;
  /** The struct the buyer signed. */
  paymentInfo: AuthCapturePaymentInfo;
  /** The signed payment as sent to the merchant. */
  payload: PaymentPayload;
  /** The `PAYMENT-RESPONSE` header as received, if any. */
  paymentResponse: string | null;
  /** That header decoded, when valid: the facilitator's settlement report. */
  settlement: SettleResponse | null;
  /** HTTP status of the service response; 0 while unanswered. */
  status: number;
  /** When the service response arrived, or the payment was signed while status is 0. */
  paidAt: string;
}

/** `decodePaymentResponseHeader` without throwing: the payment is already sent, a bad header must not lose the receipt. */
function settlementOf(header: string | null): SettleResponse | null {
  try {
    return header ? decodePaymentResponseHeader(header) : null;
  } catch {
    return null;
  }
}

/**
 * A `fetch` that pays 402s into the Kleros escrow: writes the 402 header bytes with a fresh nonce to
 * `<dir>/<paymentHash>/agreement.json`, signs with that file's keccak256 as salt, retries, writes `receipt.json`.
 */
export function klerosX402Fetch(config: KlerosX402BuyerConfig): typeof globalThis.fetch {
  const { fetch = globalThis.fetch } = config;
  return async (input, init) => {
    // One request asks for the service and is answered with the price; the same request, sent again with the payment, is answered with the service.
    const serviceRequest = new Request(input, init);
    const paymentRequest = serviceRequest.clone(); // A body can be read once, so the copy is made before the first send.
    
    const priceResponse = await fetch(serviceRequest);
    if (priceResponse.status !== 402) return priceResponse; // Nothing to pay: that was the service, or an error.
    // As the official wrapper: never pay a request that already carried a payment.
    if (serviceRequest.headers.has(PAYMENT_SIGNATURE_HEADER)) throw new Error("Payment already attempted");
    const header = priceResponse.headers.get(PAYMENT_REQUIRED_HEADER);
    if (!header) throw new Error(`402 without a ${PAYMENT_REQUIRED_HEADER} header`);
    const paymentRequired = decodePaymentRequiredHeader(header);
    if (paymentRequired.x402Version !== 2) throw new Error(`Unsupported x402Version: ${paymentRequired.x402Version}`);
    const bytes = new Uint8Array(Buffer.from(header, "base64")); // The agreement keeps the header bytes verbatim.
    const requirements = selectRequirements(config, paymentRequired);
    const agreement = buildAgreementFile(bytes);
    const payment = await createPayment(config, paymentRequired, requirements, agreement.hash);

    const paymentDir = join(config.dir, payment.paymentHash);
    mkdirSync(paymentDir, { recursive: true });
    writeFileSync(join(paymentDir, AGREEMENT_FILE_NAME), agreement.bytes);

    // Written before the signature leaves, so a failed paid request still leaves a record of what was signed.
    const receipt: KlerosX402Receipt = {
      requestUrl: priceResponse.url || serviceRequest.url,
      paymentHash: payment.paymentHash,
      salt: agreement.hash,
      paymentInfo: payment.paymentInfo,
      payload: payment.payload,
      paymentResponse: null,
      settlement: null,
      status: 0,
      paidAt: new Date().toISOString(),
    };
    const writeReceipt = () => writeFileSync(join(paymentDir, RECEIPT_FILE_NAME), JSON.stringify(receipt, null, 2));
    writeReceipt();

    paymentRequest.headers.set(PAYMENT_SIGNATURE_HEADER, encodePaymentSignatureHeader(payment.payload));
    const serviceResponse = await fetch(paymentRequest);
    receipt.paymentResponse = serviceResponse.headers.get(PAYMENT_RESPONSE_HEADER);
    receipt.settlement = settlementOf(receipt.paymentResponse);
    receipt.status = serviceResponse.status;
    receipt.paidAt = new Date().toISOString();
    writeReceipt();
    return serviceResponse;
  };
}
