import { parseAbi } from "viem";

// Facts about our contract: its ABI, the arbitrator's, and its Status enum. The tests check all of them against the contract.

/** The `KlerosCaptureAuthorizer` surface the client uses. */
export const klerosCaptureAuthorizerAbi = parseAbi([
  "struct PaymentInfo { address operator; address payer; address receiver; address token; uint120 maxAmount; uint48 preApprovalExpiry; uint48 authorizationExpiry; uint48 refundExpiry; uint16 minFeeBps; uint16 maxFeeBps; address feeReceiver; uint256 salt; }",
  "struct CaseData { bytes32 paymentHash; address payer; address receiver; address token; uint120 authorizedAmount; uint120 disputedAmount; uint120 lockedRefundAmount; uint48 disputeWindowEnd; uint8 status; uint256 ruling; string agreementURI; bytes32 salt; }",
  "function arbitrator() view returns (address)",
  "function arbitratorExtraData() view returns (bytes)",
  "function payments(bytes32 paymentHash) view returns (uint8 status, uint48 disputeWindowEnd, uint120 authorizedAmount, uint120 disputedAmount, uint120 lockedRefundAmount, uint256 disputeID, uint256 ruling, string agreementURI)",
  "function getPaymentInfo(bytes32 _paymentHash) view returns (PaymentInfo)",
  "function getCaseData(uint256 _disputeID) view returns (CaseData data)",
  "function dispute(bytes32 _paymentHash, uint120 _disputedAmount, string _agreementURI) payable returns (uint256 disputeID)",
  "function payerAccept(bytes32 _paymentHash)",
  "function merchantRefund(bytes32 _paymentHash, uint120 _newTotal)",
  "function captureIfUnchallenged(bytes32 _paymentHash)",
  "function executeRuling(bytes32 _paymentHash)",
  "event DisputeOpened(bytes32 indexed _paymentHash, uint256 indexed _disputeID, uint120 _disputedAmount)",
]);

/** The one arbitrator call the client makes. */
export const arbitratorAbi = parseAbi(["function arbitrationCost(bytes _extraData) view returns (uint256 cost)"]);

/** `Status`, in the contract's enum order. */
export const STATUS = ["None", "Authorized", "Disputed", "Resolved", "Captured", "Voided"] as const;
