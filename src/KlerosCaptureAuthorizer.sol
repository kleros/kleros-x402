// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/src/AuthCaptureEscrow.sol";
import {IArbitratorV2} from "./interfaces/IArbitratorV2.sol";
import {IArbitrableV2} from "./interfaces/IArbitrableV2.sol";
import {IDisputeTemplateRegistry} from "./interfaces/IDisputeTemplateRegistry.sol";

/// @title KlerosCaptureAuthorizer
/// @notice A bespoke x402r `captureAuthorizer` that is simultaneously the escrow
///         operator and a Kleros arbitrable. Disputes are resolved pre-capture,
///         so the contract never holds funds of its own and never touches the
///         post-capture `refund` path.
contract KlerosCaptureAuthorizer is IArbitrableV2 {
    // ************************************* //
    // *         Enums / Structs           * //
    // ************************************* //

    enum Status {
        None, // The payment does not exist.
        Authorized, // Funds are locked in escrow and the dispute window is open.
        Disputed, // The payer opened a Kleros dispute.
        Resolved, // The arbitrator ruled, execution pending.
        Captured, // The unlocked amount was captured to the merchant.
        Voided // The disputed/refunded amount was voided back to the payer, any remainder captured.
    }

    struct Payment {
        Status status; // The current status of the payment.
        uint48 disputeWindowEnd; // Authorization time + disputeWindow.
        uint120 authorizedAmount; // The amount locked in escrow.
        uint120 disputedAmount; // The amount the payer disputes.
        uint120 lockedRefundAmount; // The cumulative amount the merchant locked for refund to the payer: can only grow, paid out at settlement.
        uint256 disputeID; // The dispute ID on the arbitrator side.
        uint256 ruling; // The ruling given by the arbitrator.
        string agreementURI; // The IPFS URI of the agreement the payer pinned at dispute time; empty if none.
    }

    /// @dev Everything a juror needs about a dispute, keyed by the arbitrator-side dispute ID. Returned as a
    ///      named struct so a dispute template can read it with a single `abi/call` data mapping.
    struct CaseData {
        bytes32 paymentHash; // The escrow hash of the payment.
        address payer; // The buyer.
        address receiver; // The merchant.
        address token; // The payment token.
        uint120 authorizedAmount; // The amount locked in escrow.
        uint120 disputedAmount; // The amount the payer disputes.
        uint120 lockedRefundAmount; // The amount the merchant conceded before the dispute.
        uint48 disputeWindowEnd; // The timestamp at which the dispute window closed.
        Status status; // The current status of the payment.
        uint256 ruling; // The ruling given by the arbitrator, if any.
        string agreementURI; // The IPFS URI of the agreement the payer pinned at dispute time; empty if none.
        bytes32 salt; // `PaymentInfo.salt`, as bytes32 so the Court renders it as hex. With our SDK: the keccak256 of the agreement.
    }

    // ************************************* //
    // *             Storage               * //
    // ************************************* //

    uint256 private constant RULING_PAYER = 1; // Ruling in favor of the payer. Ruling 0 is reserved by Kleros for "refuse to arbitrate" / tie.
    uint256 private constant RULING_MERCHANT = 2; // Ruling in favor of the merchant.
    uint256 private constant RULING_OPTIONS = 2; // The number of ruling options.

    AuthCaptureEscrow public immutable escrow; // The commerce-payments escrow holding the funds.
    IArbitratorV2 public immutable arbitrator; // The trusted arbitrator resolving the disputes.
    uint256 public immutable disputeWindow; // How long the payer may dispute after authorization.
    uint256 public immutable arbitrationBuffer; // Minimum time reserved after the dispute window for arbitration to conclude and the ruling to be executed, before the escrow authorization expires. Enforced in authorize().
    uint256 public immutable templateId; // The Kleros dispute template.
    bool public immutable refuseToArbitrateCapturesToMerchant; // If Kleros refuses to arbitrate (ruling 0): true -> treated as a merchant win, false -> as a payer win.
    bytes public arbitratorExtraData; // Extra data for the arbitrator: court, number of jurors, dispute kit.

    mapping(bytes32 paymentHash => Payment) public payments; // Payments by escrow payment hash.
    mapping(bytes32 paymentHash => AuthCaptureEscrow.PaymentInfo)
        private paymentInfos; // The payment as defined by the escrow, kept so every later call needs only the hash.
    mapping(uint256 disputeID => bytes32 paymentHash) public disputeToPayment; // Maps arbitrator-side dispute IDs to payment hashes.

    // ************************************* //
    // *              Events               * //
    // ************************************* //

    /// @notice Emitted when a payment is locked in escrow and its dispute window opens.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _amount The amount locked in escrow.
    /// @param _disputeWindowEnd The timestamp at which the dispute window closes.
    event PaymentAuthorized(
        bytes32 indexed _paymentHash,
        uint120 _amount,
        uint48 _disputeWindowEnd
    );

    /// @notice Emitted when an unchallenged payment is captured to the merchant.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _amount The amount captured.
    event CapturedUnchallenged(bytes32 indexed _paymentHash, uint120 _amount);

    /// @notice Emitted when the payer releases the payment to the merchant before the dispute window ends.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _amount The amount captured.
    event PayerAccepted(bytes32 indexed _paymentHash, uint120 _amount);

    /// @notice Emitted when the payer opens a dispute.
    /// @dev Kept alongside the Kleros `DisputeRequest` event as convenience to keep the per-payment event stream filterable by hash.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _disputeID The dispute ID on the arbitrator side.
    /// @param _disputedAmount The amount the payer disputes.
    event DisputeOpened(
        bytes32 indexed _paymentHash,
        uint256 indexed _disputeID,
        uint120 _disputedAmount
    );

    /// @notice Emitted when a ruling was recorded but settling it in the same transaction failed.
    ///         The payment stays `Resolved` and `executeRuling` remains open to anyone.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _ruling The ruling that could not be settled yet.
    event SettlementDeferred(bytes32 indexed _paymentHash, uint256 _ruling);

    /// @notice Emitted when a recorded ruling is executed against the escrow.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _ruling The ruling that was executed.
    event RulingExecuted(bytes32 indexed _paymentHash, uint256 _ruling);

    /// @notice Emitted when the merchant raises their irrevocable concession to the payer.
    /// @param _paymentHash The escrow hash of the payment.
    /// @param _newTotal The new cumulative amount conceded to the payer, paid out at settlement.
    event MerchantRefunded(bytes32 indexed _paymentHash, uint120 _newTotal);

    // ************************************* //
    // *            Constructor            * //
    // ************************************* //

    /// @notice Constructor
    /// @param _escrow The commerce-payments escrow.
    /// @param _arbitrator The trusted arbitrator.
    /// @param _arbitratorExtraData Extra data for the arbitrator: court, number of jurors, dispute kit.
    /// @param _disputeWindow How long the payer may dispute after authorization.
    /// @param _arbitrationBuffer Minimum time reserved after the dispute window for arbitration and ruling execution.
    /// @param _refuseToArbitrateCapturesToMerchant Whether ruling 0 is treated as a merchant win (true) or a payer win (false).
    /// @param _templateRegistry The Kleros dispute template registry.
    /// @param _templateData The dispute template data.
    /// @param _templateDataMappings The dispute template data mappings.
    constructor(
        AuthCaptureEscrow _escrow,
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _disputeWindow,
        uint256 _arbitrationBuffer,
        bool _refuseToArbitrateCapturesToMerchant,
        IDisputeTemplateRegistry _templateRegistry,
        string memory _templateData,
        string memory _templateDataMappings
    ) {
        escrow = _escrow;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        disputeWindow = _disputeWindow;
        arbitrationBuffer = _arbitrationBuffer;
        refuseToArbitrateCapturesToMerchant = _refuseToArbitrateCapturesToMerchant;
        templateId = _templateRegistry.setDisputeTemplate(
            "KlerosCaptureAuthorizer",
            _templateData,
            _templateDataMappings
        );
    }

    // ************************************* //
    // *         State Modifiers           * //
    // ************************************* //

    /// @notice Locks the payer's funds in escrow and opens the dispute window.
    /// @dev Permissionless: the signed PaymentInfo + payer signature in `_collectorData` is the gate.
    /// @param _paymentInfo The payment as defined by the escrow. Its `operator` must be this contract.
    /// @param _amount The amount to lock in escrow, up to `_paymentInfo.maxAmount`.
    /// @param _tokenCollector The escrow collector pulling the funds, e.g. the ERC-3009 collector.
    /// @param _collectorData Collector-specific data, e.g. the payer's ERC-3009 signature.
    function authorize(
        AuthCaptureEscrow.PaymentInfo calldata _paymentInfo,
        uint256 _amount,
        address _tokenCollector,
        bytes calldata _collectorData
    ) external {
        require(_paymentInfo.operator == address(this), OperatorMismatch());
        // Via our SDK, authorizationExpiry will have the max value, basically meaning no expiry exists.
        // However, anyone can put our contract address as the operator, so as a defense mechanism, we reject short authorization windows.
        // The buffer is best-effort, not a hard guarantee. If arbitration still outlasts the authorization,
        // capture becomes impossible and the payer can reclaim the escrowed funds after expiry.
        require(
            _paymentInfo.authorizationExpiry >=
                block.timestamp + disputeWindow + arbitrationBuffer,
            AuthorizationWindowTooShort()
        );

        bytes32 paymentHash = escrow.getHash(_paymentInfo);
        Payment storage payment = payments[paymentHash];
        require(
            payment.status == Status.None,
            PaymentNotInState(Status.None, payment.status)
        );

        paymentInfos[paymentHash] = _paymentInfo;
        payment.status = Status.Authorized;
        payment.disputeWindowEnd = uint48(block.timestamp + disputeWindow);
        payment.authorizedAmount = uint120(_amount);
        emit PaymentAuthorized(
            paymentHash,
            uint120(_amount),
            payment.disputeWindowEnd
        );

        escrow.authorize(
            _paymentInfo,
            _amount,
            _tokenCollector,
            _collectorData
        );
    }

    /// @notice Captures the unconceded amount to the merchant once the dispute window has passed
    ///         unchallenged, paying out any merchant concession to the payer.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    function captureIfUnchallenged(bytes32 _paymentHash) external {
        Payment storage payment = payments[_paymentHash];
        require(
            payment.status == Status.Authorized,
            PaymentNotInState(Status.Authorized, payment.status)
        );
        require(
            block.timestamp >= payment.disputeWindowEnd,
            DisputeWindowOpen()
        );

        uint120 amount = _captureFunds(_paymentHash);
        emit CapturedUnchallenged(_paymentHash, amount);
    }

    /// @notice Lets the payer release the payment to the merchant before the dispute window ends,
    ///         e.g. once the work was delivered. Waives the right to dispute.
    /// @dev Same settlement as `captureIfUnchallenged`, which anyone can call once the window has closed.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    function payerAccept(bytes32 _paymentHash) external {
        require(msg.sender == paymentInfos[_paymentHash].payer, PayerOnly());

        Payment storage payment = payments[_paymentHash];
        require(
            payment.status == Status.Authorized,
            PaymentNotInState(Status.Authorized, payment.status)
        );

        uint120 amount = _captureFunds(_paymentHash);
        emit PayerAccepted(_paymentHash, amount);
    }

    /// @notice Opens a dispute over the specified amount. Payer-only and only while the dispute window is open.
    /// @dev The payer funds the arbitration cost via msg.value; any overpayment is refunded.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    /// @param _disputedAmount The amount the payer claims back; anything above `maxDisputable()` is clamped to it.
    /// @param _agreementURI The IPFS URI of the agreement the payer pins for the jurors: the seller's 402 response,
    ///        whose hash our SDK puts in `PaymentInfo.salt`. May be empty; the jurors then rely on evidence only.
    /// @return disputeID The dispute ID on the arbitrator side.
    function dispute(
        bytes32 _paymentHash,
        uint120 _disputedAmount,
        string calldata _agreementURI
    ) external payable returns (uint256 disputeID) {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = paymentInfos[
            _paymentHash
        ];
        require(msg.sender == paymentInfo.payer, PayerOnly());

        Payment storage payment = payments[_paymentHash];
        require(
            payment.status == Status.Authorized,
            PaymentNotInState(Status.Authorized, payment.status)
        );
        require(
            block.timestamp < payment.disputeWindowEnd,
            DisputeWindowClosed()
        );
        uint120 maxDisputableAmount = payment.authorizedAmount -
            payment.lockedRefundAmount;
        require(
            _disputedAmount > 0,
            InvalidAmount(_disputedAmount, maxDisputableAmount)
        );
        // Clamp instead of reverting: the excess is already locked for the payer, so a merchant raising
        // the concession can never invalidate an in-flight dispute by front-running it.
        uint120 disputedAmount = _disputedAmount > maxDisputableAmount
            ? maxDisputableAmount
            : _disputedAmount;

        uint256 cost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= cost, InsufficientArbitrationFee(msg.value, cost));

        payment.status = Status.Disputed;
        payment.disputedAmount = disputedAmount;
        payment.agreementURI = _agreementURI;

        disputeID = arbitrator.createDispute{value: cost}(
            RULING_OPTIONS,
            arbitratorExtraData
        );
        payment.disputeID = disputeID;
        disputeToPayment[disputeID] = _paymentHash;

        emit DisputeOpened(_paymentHash, disputeID, disputedAmount);
        // The court dispute ID doubles as the external ID so Court UI evidence submissions key on the same number.
        emit DisputeRequest(arbitrator, disputeID, disputeID, templateId, "");

        // The remainder is not contested: no ruling can send it anywhere but the merchant, so
        // capture it right away instead of making the merchant wait out the arbitration.
        uint120 remainder = maxDisputableAmount - disputedAmount;
        if (remainder > 0) {
            escrow.capture(
                paymentInfo,
                remainder,
                _feeAmount(paymentInfo, remainder),
                _feeReceiver(paymentInfo)
            );
        }

        if (msg.value > cost) {
            (bool success, ) = msg.sender.call{value: msg.value - cost}("");
            require(success, ArbitrationFeeRefundFailed());
        }
    }

    /// @notice Give a ruling for a dispute. Only callable by the arbitrator.
    /// @dev Records the ruling, then tries to settle it in the same transaction. Past the caller check this
    ///      function never reverts: the arbitrator calls it with no try/catch right after marking the dispute
    ///      ruled, so a revert here would leave that dispute unruled forever. A failed settlement is emitted and
    ///      left to the permissionless `executeRuling`.
    /// @param _disputeID The identifier of the dispute in the arbitrator contract.
    /// @param _ruling Ruling given by the arbitrator.
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(msg.sender == address(arbitrator), ArbitratorOnly());

        bytes32 paymentHash = disputeToPayment[_disputeID];
        Payment storage payment = payments[paymentHash];
        payment.status = Status.Resolved;
        payment.ruling = _ruling;
        emit Ruling(arbitrator, _disputeID, _ruling);

        try this.executeRuling(paymentHash) {} catch {
            emit SettlementDeferred(paymentHash, _ruling);
        }
    }

    /// @notice Applies a recorded ruling against the escrow. Permissionless; the fallback for a ruling
    ///         whose settlement inside `rule` failed.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    function executeRuling(bytes32 _paymentHash) external {
        Payment storage payment = payments[_paymentHash];
        require(
            payment.status == Status.Resolved,
            PaymentNotInState(Status.Resolved, payment.status)
        );

        uint256 ruling = payment.ruling;
        emit RulingExecuted(_paymentHash, ruling);
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = paymentInfos[
            _paymentHash
        ];

        bool merchantTakesAll = ruling == RULING_MERCHANT ||
            (ruling != RULING_PAYER && refuseToArbitrateCapturesToMerchant);

        if (merchantTakesAll) {
            // Merchant wins, or refuse-to-arbitrate configured to the merchant: capture the disputed amount.
            // Any locked refund still returns to the payer, win or lose.
            payment.status = Status.Captured;
            escrow.capture(
                paymentInfo,
                payment.disputedAmount,
                _feeAmount(paymentInfo, payment.disputedAmount),
                _feeReceiver(paymentInfo)
            );
            if (payment.lockedRefundAmount > 0) {
                escrow.void(paymentInfo);
            }
        } else {
            // Payer wins, or refuse-to-arbitrate configured to the payer: void the disputed amount
            // plus any locked refund back to the payer. Marked Voided to denote the payer's
            // dispute prevailed.
            payment.status = Status.Voided;
            escrow.void(paymentInfo);
        }
    }

    /// @notice Lets the merchant irrevocably concede `_newTotal` of the payment back to the payer.
    /// @dev Accounting only: funds stay in escrow and the concession is paid out at settlement, so the
    ///      payer's right to dispute the remainder is unaffected. The concession can be raised but never
    ///      lowered: the payer must be able to rely on it when deciding not to dispute. Conceding the
    ///      full amount leaves nothing contested and settles immediately.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    /// @param _newTotal The new cumulative amount conceded to the payer. Must exceed the current one.
    function merchantRefund(bytes32 _paymentHash, uint120 _newTotal) external {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = paymentInfos[
            _paymentHash
        ];
        require(msg.sender == paymentInfo.receiver, ReceiverOnly());

        Payment storage payment = payments[_paymentHash];
        require(
            payment.status == Status.Authorized,
            PaymentNotInState(Status.Authorized, payment.status)
        );
        require(
            _newTotal <= payment.authorizedAmount,
            InvalidAmount(_newTotal, payment.authorizedAmount)
        );
        require(
            _newTotal > payment.lockedRefundAmount,
            RefundNotIncreased(payment.lockedRefundAmount, _newTotal)
        );

        payment.lockedRefundAmount = _newTotal;
        emit MerchantRefunded(_paymentHash, _newTotal);

        // Everything conceded: nothing left to contest, settle immediately.
        if (_newTotal == payment.authorizedAmount) {
            payment.status = Status.Voided;
            escrow.void(paymentInfo);
        }
    }

    /// @notice Instant settlement is disabled: every payment must go authorize -> (capture | dispute).
    function charge(
        AuthCaptureEscrow.PaymentInfo calldata,
        uint256,
        address,
        bytes calldata,
        uint256,
        address
    ) external pure {
        revert ChargeDisabled();
    }

    // ************************************* //
    // *           Public Views            * //
    // ************************************* //

    /// @notice Returns the maximum amount the payer can still dispute: the authorized amount minus
    ///         the merchant's concession.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    /// @return The amount a dispute can still claim; larger requests are clamped to it.
    function maxDisputable(
        bytes32 _paymentHash
    ) external view returns (uint120) {
        Payment storage payment = payments[_paymentHash];
        return payment.authorizedAmount - payment.lockedRefundAmount;
    }

    /// @notice Returns the payment as defined by the escrow, as stored at authorization.
    /// @param _paymentHash The escrow hash of the payment, as returned by `escrow.getHash`.
    /// @return The stored `PaymentInfo`; all-zero if the payment does not exist.
    function getPaymentInfo(
        bytes32 _paymentHash
    ) external view returns (AuthCaptureEscrow.PaymentInfo memory) {
        return paymentInfos[_paymentHash];
    }

    /// @notice Returns the facts of a dispute for the Court, keyed by the arbitrator-side dispute ID.
    /// @param _disputeID The dispute ID on the arbitrator side.
    /// @return data The case facts.
    function getCaseData(
        uint256 _disputeID
    ) external view returns (CaseData memory data) {
        bytes32 paymentHash = disputeToPayment[_disputeID];
        Payment storage payment = payments[paymentHash];
        require(payment.status != Status.None, UnknownDispute(_disputeID));
        AuthCaptureEscrow.PaymentInfo storage paymentInfo = paymentInfos[
            paymentHash
        ];
        data = CaseData({
            paymentHash: paymentHash,
            payer: paymentInfo.payer,
            receiver: paymentInfo.receiver,
            token: paymentInfo.token,
            authorizedAmount: payment.authorizedAmount,
            disputedAmount: payment.disputedAmount,
            lockedRefundAmount: payment.lockedRefundAmount,
            disputeWindowEnd: payment.disputeWindowEnd,
            status: payment.status,
            ruling: payment.ruling,
            agreementURI: payment.agreementURI,
            salt: bytes32(paymentInfo.salt)
        });
    }

    // ************************************* //
    // *            Internal               * //
    // ************************************* //

    /// @dev Captures everything the merchant did not concede to the merchant and voids the concession,
    ///      if any, back to the payer. Used when nobody disputed the payment.
    /// @param _paymentHash The escrow hash of the payment.
    /// @return amount The amount captured to the merchant.
    function _captureFunds(
        bytes32 _paymentHash
    ) internal returns (uint120 amount) {
        Payment storage payment = payments[_paymentHash];
        payment.status = Status.Captured;
        amount = payment.authorizedAmount - payment.lockedRefundAmount;

        AuthCaptureEscrow.PaymentInfo memory paymentInfo = paymentInfos[
            _paymentHash
        ];
        escrow.capture(
            paymentInfo,
            amount,
            _feeAmount(paymentInfo, amount),
            _feeReceiver(paymentInfo)
        );
        // Pay out any concession the merchant recorded during the window.
        if (payment.lockedRefundAmount > 0) {
            escrow.void(paymentInfo);
        }
    }

    /// @dev Computes the fee submitted with a capture: the payment's `minFeeBps` applied to the captured
    ///      amount, rounded down as the escrow does. The contract takes no fee of its own.
    /// @param _paymentInfo The payment as defined by the escrow.
    /// @param _amount The amount being captured.
    /// @return The absolute fee amount, in token units.
    function _feeAmount(
        AuthCaptureEscrow.PaymentInfo memory _paymentInfo,
        uint256 _amount
    ) internal pure returns (uint256) {
        return (_amount * _paymentInfo.minFeeBps) / 10_000;
    }

    /// @dev Resolves the fee receiver. A payment may leave `feeReceiver` unset (0), meaning the operator
    ///      picks one at capture; we always pick the merchant. The escrow ignores the receiver when the
    ///      fee is zero, so this is safe for fee-free payments too.
    function _feeReceiver(
        AuthCaptureEscrow.PaymentInfo memory _paymentInfo
    ) internal pure returns (address) {
        return
            _paymentInfo.feeReceiver == address(0)
                ? _paymentInfo.receiver
                : _paymentInfo.feeReceiver;
    }

    // ************************************* //
    // *              Errors               * //
    // ************************************* //

    error OperatorMismatch();
    error AuthorizationWindowTooShort();
    error PaymentNotInState(Status _expected, Status _actual);
    error DisputeWindowOpen();
    error DisputeWindowClosed();
    error PayerOnly();
    error ReceiverOnly();
    error ArbitratorOnly();
    error InvalidAmount(uint120 _requested, uint120 _max);
    error RefundNotIncreased(uint120 _current, uint120 _requested);
    error InsufficientArbitrationFee(uint256 _sent, uint256 _required);
    error ArbitrationFeeRefundFailed();
    error UnknownDispute(uint256 _disputeID);
    error ChargeDisabled();
}
