import { randomBytes } from "node:crypto";
import { keccak256, toHex, type Hex } from "viem";

/** Name of the agreement file when it is pinned. The juror policy refers to it by this name. */
export const AGREEMENT_FILE_NAME = "agreement.json";

/**
 * The agreement file, one line: `{"nonce":"0x<64 hex>","paymentRequired":<402 header bytes verbatim>}`.
 * Its keccak256 is the payment's salt; jurors check `cast keccak < agreement.json` against it.
 * The 32 random nonce bytes give repeat purchases of the same offer different salts.
 * @param paymentRequired - The `PAYMENT-REQUIRED` header base64-decoded, never re-serialized.
 * @returns The bytes to keep and pin as-is, and their keccak256.
 */
export function buildAgreementFile(paymentRequired: Uint8Array): { bytes: Uint8Array; hash: Hex } {
  const bytes = new Uint8Array(
    Buffer.concat([
      Buffer.from(`{"nonce":"${toHex(randomBytes(32))}","paymentRequired":`, "utf8"),
      Buffer.from(paymentRequired),
      Buffer.from("}", "utf8"),
    ]),
  );
  return { bytes, hash: keccak256(bytes) };
}
