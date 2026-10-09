import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  hexToBigInt,
  isHash,
  keccak256,
  parseEventLogs,
  type Account,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { AGREEMENT_FILE_NAME } from "./agreement.ts";
import { STATUS, arbitratorAbi, klerosCaptureAuthorizerAbi } from "./contractTypes.ts";
import { deploymentFor } from "./deployments.ts";

/** Pins `file` under `name` and returns the URI the Court resolves, e.g. `/ipfs/<cid>`. */
export type Pinner = (file: Uint8Array<ArrayBuffer>, name: string) => Promise<string>;

export interface KlerosX402Config {
  publicClient: PublicClient<Transport, Chain>;
  /** Needed for the calls that send transactions; its account is the caller. */
  walletClient?: WalletClient<Transport, Chain, Account>;
}

/** Pin the agreement from the buyer's folder, or name where it is pinned. Empty `agreementURI` = no agreement. */
export type DisputeArgs = { paymentHash: Hex; disputedAmount: bigint } & (
  | { agreementDir: string; pin: Pinner }
  | { agreementURI: string }
);

/** The gateway the Court resolves `/ipfs/<cid>` through. */
const COURT_GATEWAY = "https://cdn.kleros.link";
/** A fresh pin takes a moment to become readable; the read-back, retries included, gives up after this. */
const PIN_READ_TIMEOUT_MS = 60_000;

/** Reads the pinned file the way jurors will; every attempt, body included, is bounded by the deadline. */
async function readPinned(uri: string): Promise<Uint8Array> {
  const deadline = Date.now() + PIN_READ_TIMEOUT_MS;
  let last = "";
  for (let remaining = PIN_READ_TIMEOUT_MS; remaining > 0; remaining = deadline - Date.now()) {
    try {
      const response = await fetch(`${COURT_GATEWAY}${uri}`, { signal: AbortSignal.timeout(remaining) });
      if (response.ok) return new Uint8Array(await response.arrayBuffer());
      last = `status ${response.status}`;
    } catch (error) {
      last = error instanceof Error ? error.message : String(error);
    }
    await new Promise((resolve) => setTimeout(resolve, Math.min(3000, Math.max(0, deadline - Date.now()))));
  }
  throw new Error(`${uri} is not readable through ${COURT_GATEWAY} within ${PIN_READ_TIMEOUT_MS / 1000} s (${last})`);
}

/** `/ipfs/<cid>`, the form the Court resolves from the case page, from that, `<cid>` or `ipfs://<cid>`; anything else is refused. */
function toCourtUri(uri: string): string {
  const path = uri.replace(/^ipfs:\/\//, "").replace(/^\/ipfs\//, "");
  if (!/^[A-Za-z0-9]+(\/[^\s]*)?$/.test(path)) throw new Error(`Not an IPFS URI, expected /ipfs/<cid>, <cid> or ipfs://<cid>: ${uri}`);
  return `/ipfs/${path}`;
}

/** The agreement the payment was signed with hashes to the salt the escrow stores. */
const hashesToSalt = (file: Uint8Array, salt: bigint) => hexToBigInt(keccak256(file)) === salt;

/**
 * The agreement URI to put on chain: "" for none; else the Court URI of a file that hashes to the payment's salt,
 * checked on the local file before pinning and on the pinned file after reading it back, as jurors will.
 */
async function verifiedAgreementUri(args: DisputeArgs, readSalt: () => Promise<bigint>): Promise<string> {
  const alreadyPinned = "agreementURI" in args;
  // No agreement.
  if (alreadyPinned && args.agreementURI === "") return "";
  const salt = await readSalt();
  let uri: string;
  if (alreadyPinned) {
    // Already pinned.
    uri = args.agreementURI;
  } else {
    // The file the buyer's fetch wrapper wrote; pin it only if it is the one the payment was signed with.
    const local = readFileSync(join(args.agreementDir, args.paymentHash, AGREEMENT_FILE_NAME));
    if (!hashesToSalt(local, salt)) throw new Error("The local agreement does not hash to the payment's salt");
    uri = await args.pin(local, AGREEMENT_FILE_NAME);
  }
  // Read it back as jurors will and check it against the salt.
  uri = toCourtUri(uri);
  if (!hashesToSalt(await readPinned(uri), salt)) throw new Error(`The file at ${uri} does not hash to the payment's salt`);
  return uri;
}

export function klerosX402Client(config: KlerosX402Config) {
  const { publicClient, walletClient } = config;
  // Reads and transactions on different chains would send value to a dead address.
  if (walletClient && walletClient.chain.id !== publicClient.chain.id) {
    throw new Error(`walletClient is on chain ${walletClient.chain.id}, publicClient on ${publicClient.chain.id}`);
  }
  const { operator, courtUrl } = deploymentFor(`eip155:${publicClient.chain.id}`);
  const contract = { address: operator, abi: klerosCaptureAuthorizerAbi } as const;
  const wallet = () => {
    if (!walletClient) throw new Error("walletClient is required to send transactions");
    return walletClient;
  };
  const courtCaseUrl = (disputeID: bigint) => `${courtUrl}/#/cases/${disputeID}/overview`;

  return {
    courtCaseUrl,

    /** Get payment information */
    async payment(paymentHash: Hex) {
      const [[status, disputeWindowEnd, authorizedAmount, disputedAmount, lockedRefundAmount, disputeID, ruling, agreementURI], paymentInfo] =
        await Promise.all([
          publicClient.readContract({ ...contract, functionName: "payments", args: [paymentHash] }),
          publicClient.readContract({ ...contract, functionName: "getPaymentInfo", args: [paymentHash] }),
        ]);
      return {
        status: STATUS[status],
        disputeWindowEnd,
        authorizedAmount,
        disputedAmount,
        lockedRefundAmount,
        disputeID,
        ruling,
        agreementURI,
        paymentInfo,
      };
    },

    /** Get a payment dispute case data. Convenience only. */
    async caseData(disputeID: bigint) {
      const data = await publicClient.readContract({ ...contract, functionName: "getCaseData", args: [disputeID] });
      return { ...data, status: STATUS[data.status] };
    },

    /** Payer only. Pins the agreement, pays the arbitration cost, opens the dispute. */
    async dispute(args: DisputeArgs) {
      const signer = wallet();
      // The hash is also the name of the folder the buyer client stores the payment in.
      if (!isHash(args.paymentHash)) throw new Error(`Not a payment hash: ${args.paymentHash}`);
      const agreementURI = await verifiedAgreementUri(args, async () => {
        const info = await publicClient.readContract({ ...contract, functionName: "getPaymentInfo", args: [args.paymentHash] });
        return info.salt;
      });
      const arbitrator = await publicClient.readContract({ ...contract, functionName: "arbitrator" });
      const extraData = await publicClient.readContract({ ...contract, functionName: "arbitratorExtraData" });
      const value = await publicClient.readContract({
        address: arbitrator,
        abi: arbitratorAbi,
        functionName: "arbitrationCost",
        args: [extraData],
      });
      const hash = await signer.writeContract({
        ...contract,
        functionName: "dispute",
        args: [args.paymentHash, args.disputedAmount, agreementURI],
        value,
      });
      // Only the mined event says which dispute ID is ours, and carries the amount after the contract's clamp.
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === "reverted") throw new Error(`Dispute transaction ${hash} reverted`);
      const logs = receipt.logs.filter((log) => log.address.toLowerCase() === operator.toLowerCase());
      const [opened] = parseEventLogs({ abi: klerosCaptureAuthorizerAbi, eventName: "DisputeOpened", logs });
      if (!opened) throw new Error(`Transaction ${hash} did not open a dispute`);
      const disputeID = opened.args._disputeID;
      return { hash, disputeID, disputedAmount: opened.args._disputedAmount, agreementURI, courtUrl: courtCaseUrl(disputeID) };
    },

    /** Payer only. Releases the payment to the merchant before the dispute window ends. */
    payerAccept: async (paymentHash: Hex) =>
      wallet().writeContract({ ...contract, functionName: "payerAccept", args: [paymentHash] }),

    /** Merchant only. Raises the total refunded to the payer; refunding all settles the payment. */
    merchantRefund: async (paymentHash: Hex, newTotal: bigint) =>
      wallet().writeContract({ ...contract, functionName: "merchantRefund", args: [paymentHash, newTotal] }),

    /** Anyone, once the dispute window closed without a dispute. */
    captureIfUnchallenged: async (paymentHash: Hex) =>
      wallet().writeContract({ ...contract, functionName: "captureIfUnchallenged", args: [paymentHash] }),

    /** Anyone, for a ruling the arbitrator could not settle in its own transaction. */
    executeRuling: async (paymentHash: Hex) =>
      wallet().writeContract({ ...contract, functionName: "executeRuling", args: [paymentHash] }),
  };
}

/** A `Pinner` for Pinata's Files API. Read the JWT from the environment, never commit it. */
export function pinataPinner(jwt: string): Pinner {
  return async (file, name) => {
    const body = new FormData();
    body.append("file", new Blob([file]), name);
    body.append("network", "public");
    const response = await fetch("https://uploads.pinata.cloud/v3/files", {
      method: "POST",
      headers: { Authorization: `Bearer ${jwt}` },
      body,
    });
    if (!response.ok) throw new Error(`Pinata upload failed with status ${response.status}`);
    const { data } = (await response.json()) as { data?: { cid?: unknown } };
    if (typeof data?.cid !== "string" || data.cid === "") throw new Error("Pinata upload returned no CID");
    return `/ipfs/${data.cid}`;
  };
}
