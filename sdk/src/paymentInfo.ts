import { encodeAbiParameters, keccak256, parseAbiParameters, toBytes, zeroAddress, type Address, type Hex } from "viem";
import type { AuthCapturePaymentInfo } from "@x402/evm";

// Port of x402's internal auth-capture hashing (`nonce.ts`), which `@x402/evm` does not export.

/** EIP-712 type hash of `PaymentInfo`, the first word of the escrow's struct hash. */
const PAYMENT_INFO_TYPEHASH = keccak256(
  toBytes(
    "PaymentInfo(address operator,address payer,address receiver,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 minFeeBps,uint16 maxFeeBps,address feeReceiver,uint256 salt)",
  ),
);

/** `AuthCaptureEscrow.getHash`: the escrow's key for a payment, and the `paymentHash` every operator call takes. */
export function paymentHash(chainId: number, info: AuthCapturePaymentInfo, escrow: Address): Hex {
  return hashWithPayer(chainId, info, info.payer, escrow);
}

/**
 * The ERC-3009 `nonce` the buyer signs: the payment hash with the payer zeroed, as the escrow's token
 * collector recomputes it at `authorize`. Binds the authorization to this payment in this escrow.
 */
export function payerAgnosticPaymentHash(chainId: number, info: AuthCapturePaymentInfo, escrow: Address): Hex {
  return hashWithPayer(chainId, info, zeroAddress, escrow);
}

/** The escrow's formula, shared by both hashes above: the struct hash, then chain id and escrow address on top. */
function hashWithPayer(chainId: number, info: AuthCapturePaymentInfo, payer: Address, escrow: Address): Hex {
  const structHash = keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32, address, address, address, address, uint120, uint48, uint48, uint48, uint16, uint16, address, uint256"),
      [
        PAYMENT_INFO_TYPEHASH,
        info.operator,
        payer,
        info.receiver,
        info.token,
        BigInt(info.maxAmount),
        info.preApprovalExpiry,
        info.authorizationExpiry,
        info.refundExpiry,
        info.minFeeBps,
        info.maxFeeBps,
        info.feeReceiver,
        BigInt(info.salt),
      ],
    ),
  );
  return keccak256(encodeAbiParameters(parseAbiParameters("uint256, address, bytes32"), [BigInt(chainId), escrow, structHash]));
}

/** The chain id of a CAIP-2 EVM network, `eip155:<decimal>` only. */
export function evmChainId(network: string): number {
  const match = /^eip155:(\d+)$/.exec(network);
  const chainId = match ? Number(match[1]) : NaN;
  if (!Number.isSafeInteger(chainId)) throw new Error(`Unsupported network: ${network}`);
  return chainId;
}
