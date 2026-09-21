// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AuthCaptureEscrow} from "commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "commerce-payments/src/collectors/ERC3009PaymentCollector.sol";
import {MockERC3009Token} from "commerce-payments/test/mocks/MockERC3009Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArbitratorV2} from "../src/interfaces/IArbitratorV2.sol";
import {IArbitrableV2} from "../src/interfaces/IArbitrableV2.sol";
import {IDisputeTemplateRegistry} from "../src/interfaces/IDisputeTemplateRegistry.sol";

import {KlerosCaptureAuthorizer} from "../src/KlerosCaptureAuthorizer.sol";

/// @dev Minimal arbitrator: fixed cost, incrementing dispute IDs, rulings relayed
///      via `giveRuling` so the arbitrable sees the arbitrator as msg.sender.
contract StubArbitrator is IArbitratorV2 {
    uint256 public immutable cost;
    uint256 public nextDisputeID = 1;
    mapping(uint256 disputeID => uint256) public rulings;

    constructor(uint256 _cost) {
        cost = _cost;
    }

    function createDispute(
        uint256,
        bytes calldata
    ) external payable returns (uint256 disputeID) {
        disputeID = nextDisputeID++;
    }

    function createDispute(
        uint256,
        bytes calldata,
        IERC20,
        uint256
    ) external pure returns (uint256) {
        revert("ERC20 fees unsupported");
    }

    function arbitrationCost(bytes calldata) external view returns (uint256) {
        return cost;
    }

    function arbitrationCost(
        bytes calldata,
        IERC20
    ) external pure returns (uint256) {
        revert("ERC20 fees unsupported");
    }

    function currentRuling(
        uint256 _disputeID
    ) external view returns (uint256 ruling, bool tied, bool overridden) {
        return (rulings[_disputeID], false, false);
    }

    function giveRuling(
        IArbitrableV2 _arbitrable,
        uint256 _disputeID,
        uint256 _ruling
    ) external {
        rulings[_disputeID] = _ruling;
        _arbitrable.rule(_disputeID, _ruling);
    }
}

/// @dev Minimal registry: stores templates and hands out sequential ids.
contract MockTemplateRegistry is IDisputeTemplateRegistry {
    uint256 public templateCount;
    mapping(uint256 templateId => string) public templateTags;
    mapping(uint256 templateId => string) public templateData;
    mapping(uint256 templateId => string) public templateDataMappings;

    function setDisputeTemplate(
        string memory _templateTag,
        string memory _templateData,
        string memory _templateDataMappings
    ) external returns (uint256 templateId) {
        templateId = templateCount++;
        templateTags[templateId] = _templateTag;
        templateData[templateId] = _templateData;
        templateDataMappings[templateId] = _templateDataMappings;
        emit DisputeTemplate(
            templateId,
            _templateTag,
            _templateData,
            _templateDataMappings
        );
    }
}

/// @dev Contract payer accepting any signature (ERC-1271) but rejecting ETH: reaches the
///      ArbitrationFeeRefundFailed branch of dispute().
contract RejectingPayer {
    function isValidSignature(
        bytes32,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0x1626ba7e; // ERC-1271 magic value.
    }

    function openDispute(
        KlerosCaptureAuthorizer _ca,
        bytes32 _paymentHash,
        uint120 _amount
    ) external payable {
        _ca.dispute{value: msg.value}(_paymentHash, _amount, "");
    }
}

/// @dev Contract payer that re-enters the operator from the arbitration-fee refund hook and swallows
///      the failures, so the outer call proceeds and the state after it can be inspected.
contract ReentrantPayer {
    KlerosCaptureAuthorizer public ca;
    bytes32 public paymentHash;
    uint256 public failures;

    function isValidSignature(
        bytes32,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0x1626ba7e; // ERC-1271 magic value.
    }

    function openDispute(
        KlerosCaptureAuthorizer _ca,
        bytes32 _paymentHash,
        uint120 _amount
    ) external payable returns (uint256) {
        ca = _ca;
        paymentHash = _paymentHash;
        return _ca.dispute{value: msg.value}(_paymentHash, _amount, "");
    }

    receive() external payable {
        try ca.dispute(paymentHash, 1, "") {} catch {
            failures++;
        }
        try ca.payerAccept(paymentHash) {} catch {
            failures++;
        }
        try ca.captureIfUnchallenged(paymentHash) {} catch {
            failures++;
        }
        try ca.executeRuling(paymentHash) {} catch {
            failures++;
        }
    }
}

contract KlerosCaptureAuthorizerTest is Test {
    uint256 constant DISPUTE_WINDOW = 3 days;
    uint256 constant ARBITRATION_BUFFER = 7 days;
    uint256 constant ARBITRATION_COST = 0.03 ether;
    uint120 constant AMOUNT = 100e6;
    uint256 constant PAYER_BALANCE = 1_000e6;
    uint256 constant RULING_REFUSED = 0;
    uint256 constant RULING_PAYER = 1;
    uint256 constant RULING_MERCHANT = 2;
    string constant TEMPLATE_DATA = '{"title": "test template"}';
    string constant TEMPLATE_MAPPINGS = "[]";
    string constant AGREEMENT_URI =
        "/ipfs/bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/agreement.json";

    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    AuthCaptureEscrow escrow;
    MockERC3009Token token;
    ERC3009PaymentCollector collector;
    StubArbitrator arbitrator;
    MockTemplateRegistry templateRegistry;
    KlerosCaptureAuthorizer ca;

    uint256 payerPk = 0xA11CE;
    address payer;
    address merchant;

    function setUp() public {
        escrow = new AuthCaptureEscrow();
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        // Multicall3 is only reached for ERC-6492 wrapped signatures; plain EOA sigs never touch it.
        collector = new ERC3009PaymentCollector(
            address(escrow),
            0xcA11bde05977b3631167028862bE2a173976CA11
        );
        arbitrator = new StubArbitrator(ARBITRATION_COST);
        templateRegistry = new MockTemplateRegistry();
        ca = new KlerosCaptureAuthorizer({
            _escrow: escrow,
            _arbitrator: arbitrator,
            _arbitratorExtraData: "",
            _disputeWindow: DISPUTE_WINDOW,
            _arbitrationBuffer: ARBITRATION_BUFFER,
            _refuseToArbitrateCapturesToMerchant: true,
            _templateRegistry: templateRegistry,
            _templateData: TEMPLATE_DATA,
            _templateDataMappings: TEMPLATE_MAPPINGS
        });

        payer = vm.addr(payerPk);
        vm.label(payer, "payer");
        merchant = makeAddr("merchant");

        token.mint(payer, PAYER_BALANCE);
    }

    // ************************************* //
    // *              Helpers              * //
    // ************************************* //

    function _paymentInfo()
        internal
        view
        returns (AuthCaptureEscrow.PaymentInfo memory)
    {
        return
            AuthCaptureEscrow.PaymentInfo({
                operator: address(ca),
                payer: payer,
                receiver: merchant,
                token: address(token),
                maxAmount: AMOUNT,
                preApprovalExpiry: uint48(block.timestamp + 1 hours),
                authorizationExpiry: uint48(
                    block.timestamp +
                        DISPUTE_WINDOW +
                        ARBITRATION_BUFFER +
                        1 days
                ),
                refundExpiry: uint48(
                    block.timestamp +
                        DISPUTE_WINDOW +
                        ARBITRATION_BUFFER +
                        1 days
                ),
                minFeeBps: 0,
                maxFeeBps: 0,
                feeReceiver: address(0),
                salt: 1
            });
    }

    /// @dev ERC-3009 signature over the payer-agnostic PaymentInfo hash, as the collector expects.
    function _sign(
        AuthCaptureEscrow.PaymentInfo memory paymentInfo
    ) internal view returns (bytes memory) {
        address originalPayer = paymentInfo.payer;
        paymentInfo.payer = address(0);
        bytes32 nonce = escrow.getHash(paymentInfo);
        paymentInfo.payer = originalPayer;

        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                paymentInfo.payer,
                address(collector),
                uint256(paymentInfo.maxAmount),
                uint256(0),
                uint256(paymentInfo.preApprovalExpiry),
                nonce
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authorize()
        internal
        returns (AuthCaptureEscrow.PaymentInfo memory paymentInfo)
    {
        paymentInfo = _paymentInfo();
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
    }

    /// @dev Opens a dispute as the payer, funding the exact arbitration cost.
    function _dispute(
        AuthCaptureEscrow.PaymentInfo memory paymentInfo,
        uint120 disputedAmount
    ) internal returns (uint256 disputeID) {
        bytes32 paymentHash = _hash(paymentInfo);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        disputeID = ca.dispute{value: ARBITRATION_COST}(
            paymentHash,
            disputedAmount,
            AGREEMENT_URI
        );
    }

    /// @dev The escrow's key for a payment. Fetch it on its own line before any `vm.prank` or
    ///      `vm.expectRevert`: those attach to the next external call, and this is one.
    function _hash(
        AuthCaptureEscrow.PaymentInfo memory paymentInfo
    ) internal view returns (bytes32) {
        return escrow.getHash(paymentInfo);
    }

    function _status(
        AuthCaptureEscrow.PaymentInfo memory paymentInfo
    ) internal view returns (KlerosCaptureAuthorizer.Status status) {
        (status, , , , , , , ) = ca.payments(escrow.getHash(paymentInfo));
    }

    // ************************************* //
    // *            constructor            * //
    // ************************************* //

    /// @dev The constructor registers the template once and keeps the id the registry returned.
    function test_constructor_registersTemplate() public view {
        assertEq(ca.templateId(), 0, "first template registered by the mock");
        assertEq(templateRegistry.templateCount(), 1);
        assertEq(templateRegistry.templateTags(0), "KlerosCaptureAuthorizer");
        assertEq(templateRegistry.templateData(0), TEMPLATE_DATA);
        assertEq(templateRegistry.templateDataMappings(0), TEMPLATE_MAPPINGS);
    }

    // ************************************* //
    // *            authorize              * //
    // ************************************* //

    /// @dev An authorizationExpiry of exactly disputeWindow + arbitrationBuffer must be accepted.
    function test_authorize_acceptsExactFitExpiry() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.authorizationExpiry = uint48(
            block.timestamp + DISPUTE_WINDOW + ARBITRATION_BUFFER
        );

        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );

        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Authorized)
        );
    }

    /// @dev The contract must account with the actually-authorized amount, not the payment's maxAmount cap.
    function test_authorize_partialAmount_accountsWithAuthorizedAmount()
        public
    {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        uint120 authorizedAmount = 60e6;
        ca.authorize(
            paymentInfo,
            authorizedAmount,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - authorizedAmount,
            "only the authorized amount should be escrowed"
        );
        assertEq(
            ca.maxDisputable(paymentHash),
            authorizedAmount,
            "accounting should track the authorized amount"
        );

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);
        assertEq(
            token.balanceOf(merchant),
            authorizedAmount,
            "capture should pay exactly the authorized amount"
        );
    }

    /// @dev The struct is stored at authorization so every later call, and any keeper, needs only the hash.
    function test_authorize_storesPaymentInfo() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        AuthCaptureEscrow.PaymentInfo memory stored = ca.getPaymentInfo(
            paymentHash
        );
        assertEq(
            keccak256(abi.encode(stored)),
            keccak256(abi.encode(paymentInfo)),
            "stored PaymentInfo should match"
        );
        assertEq(
            escrow.getHash(stored),
            paymentHash,
            "stored PaymentInfo should re-hash to the same key"
        );
    }

    function test_authorize_revert_operatorMismatch() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.operator = makeAddr("someoneElse");

        vm.expectRevert(KlerosCaptureAuthorizer.OperatorMismatch.selector);
        ca.authorize(paymentInfo, AMOUNT, address(collector), "");
    }

    function test_authorize_revert_authorizationWindowTooShort() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.authorizationExpiry = uint48(
            block.timestamp + DISPUTE_WINDOW + ARBITRATION_BUFFER - 1
        );

        vm.expectRevert(
            KlerosCaptureAuthorizer.AuthorizationWindowTooShort.selector
        );
        ca.authorize(paymentInfo, AMOUNT, address(collector), "");
    }

    function test_authorize_revert_alreadyAuthorized() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        // Precomputed: _sign makes external calls, which would disarm vm.expectRevert.
        bytes memory signature = _sign(paymentInfo);

        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.None,
                KlerosCaptureAuthorizer.Status.Authorized
            )
        );
        ca.authorize(paymentInfo, AMOUNT, address(collector), signature);
    }

    /// @dev The keeper takes the hash and the window end from this event: assert its fields.
    function test_authorize_emitsPaymentAuthorized() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        bytes32 paymentHash = _hash(paymentInfo);
        bytes memory signature = _sign(paymentInfo);

        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.PaymentAuthorized(
            paymentHash,
            AMOUNT,
            uint48(block.timestamp + DISPUTE_WINDOW)
        );
        ca.authorize(paymentInfo, AMOUNT, address(collector), signature);
    }

    // ************************************* //
    // *      captureIfUnchallenged        * //
    // ************************************* //

    function test_happyPath_captureIfUnchallenged() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "funds not pulled into escrow"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Authorized)
        );

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(token.balanceOf(merchant), AMOUNT, "merchant not paid");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    /// @dev The dispute window is [authorize, end): capture must succeed exactly at the end.
    function test_captureIfUnchallenged_exactlyAtWindowEnd() public {
        uint256 windowEnd = block.timestamp + DISPUTE_WINDOW;
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(windowEnd);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(token.balanceOf(merchant), AMOUNT, "merchant not paid");
    }

    /// @dev With a non-zero fee and no configured feeReceiver, the fee defaults to the merchant.
    function test_captureIfUnchallenged_feeDefaultsToMerchant() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(merchant),
            AMOUNT,
            "fee should default to the merchant"
        );
    }

    function test_captureIfUnchallenged_feePaidToFeeReceiver() public {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        paymentInfo.feeReceiver = feeRecipient;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(feeRecipient),
            1e6,
            "fee receiver should get 1%"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - 1e6,
            "merchant should get the rest"
        );
    }

    /// @dev Pins the always-capture-at-minFeeBps policy against an asymmetric fee range.
    function test_captureIfUnchallenged_asymmetricFeeRange_usesMinFeeBps()
        public
    {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 500;
        paymentInfo.feeReceiver = feeRecipient;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(feeRecipient),
            1e6,
            "fee should be exactly minFeeBps"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - 1e6,
            "merchant should get the rest"
        );
    }

    /// @dev With a concession recorded, the fee applies only to the unlocked share captured to the
    ///      merchant; the concession is voided back to the payer fee-free.
    function test_captureIfUnchallenged_feeAppliesOnlyToUnlockedShare() public {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        paymentInfo.feeReceiver = feeRecipient;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 40e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(feeRecipient),
            0.6e6,
            "fee should be 1% of the unlocked share only"
        );
        assertEq(
            token.balanceOf(merchant),
            60e6 - 0.6e6,
            "merchant should get the unlocked share minus fee"
        );
        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + conceded,
            "concession should return fee-free"
        );
    }

    /// @dev v1.1 escrow: the submitted fee is an absolute amount, minFeeBps applied to the captured
    ///      amount and rounded down, so a 1% fee on an odd amount must not revert on the escrow's range check.
    function test_captureIfUnchallenged_feeAmountRoundsDown() public {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        paymentInfo.feeReceiver = feeRecipient;
        uint120 oddAmount = 12_345;
        ca.authorize(
            paymentInfo,
            oddAmount,
            address(collector),
            _sign(paymentInfo)
        );
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(feeRecipient),
            123,
            "fee should be 1% rounded down"
        );
        assertEq(
            token.balanceOf(merchant),
            oddAmount - 123,
            "merchant should get the rest"
        );
    }

    function test_captureIfUnchallenged_revert_windowStillOpen() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW - 1);
        vm.expectRevert(KlerosCaptureAuthorizer.DisputeWindowOpen.selector);
        ca.captureIfUnchallenged(paymentHash);
    }

    function test_captureIfUnchallenged_revert_notAuthorized() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Authorized,
                KlerosCaptureAuthorizer.Status.None
            )
        );
        ca.captureIfUnchallenged(paymentHash);
    }

    /// @dev The event carries the merchant's share, net of any concession.
    function test_captureIfUnchallenged_emitsCapturedUnchallenged() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint120 conceded = 40e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);
        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.CapturedUnchallenged(
            paymentHash,
            AMOUNT - conceded
        );
        ca.captureIfUnchallenged(paymentHash);
    }

    // ************************************* //
    // *           payerAccept             * //
    // ************************************* //

    function test_payerAccept_capturesInsideWindow() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(payer);
        ca.payerAccept(paymentHash);

        assertEq(token.balanceOf(merchant), AMOUNT, "merchant not paid");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );

        // Accepting waives the right to dispute.
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Authorized,
                KlerosCaptureAuthorizer.Status.Captured
            )
        );
        ca.dispute{value: ARBITRATION_COST}(paymentHash, AMOUNT, AGREEMENT_URI);
    }

    function test_payerAccept_paysOutConcession() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint120 conceded = 40e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        vm.prank(payer);
        ca.payerAccept(paymentHash);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + conceded,
            "payer should get the concession"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - conceded,
            "merchant should keep the remainder"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    /// @dev No time check: after the window anyone can capture anyway, so the payer may as well.
    function test_payerAccept_worksAfterWindow() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(payer);
        ca.payerAccept(paymentHash);

        assertEq(token.balanceOf(merchant), AMOUNT, "merchant not paid");
    }

    function test_payerAccept_emitsPayerAccepted() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint120 conceded = 40e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        vm.prank(payer);
        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.PayerAccepted(
            paymentHash,
            AMOUNT - conceded
        );
        ca.payerAccept(paymentHash);
    }

    function test_payerAccept_revert_payerOnly() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(merchant);
        vm.expectRevert(KlerosCaptureAuthorizer.PayerOnly.selector);
        ca.payerAccept(paymentHash);
    }

    function test_payerAccept_revert_unknownPayment() public {
        vm.prank(payer);
        vm.expectRevert(KlerosCaptureAuthorizer.PayerOnly.selector);
        ca.payerAccept(keccak256("unknown"));
    }

    function test_payerAccept_revert_notAuthorized() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        _dispute(paymentInfo, AMOUNT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Authorized,
                KlerosCaptureAuthorizer.Status.Disputed
            )
        );
        ca.payerAccept(paymentHash);
    }

    // ************************************* //
    // *             dispute               * //
    // ************************************* //

    function test_dispute_fullRefund_payerWins() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        uint256 disputeID = _dispute(paymentInfo, AMOUNT);
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "payer not fully refunded"
        );
        assertEq(token.balanceOf(merchant), 0, "merchant should get nothing");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev A partial dispute concedes the remainder (captured to the merchant at dispute time):
    ///      on a payer win only the disputed amount is voided back.
    function test_dispute_partialRefund_payerWins() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + disputedAmount,
            "payer should recover the disputed amount"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "merchant should keep the conceded remainder"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    function test_dispute_merchantWins() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        uint256 disputeID = _dispute(paymentInfo, 30e6);

        arbitrator.giveRuling(ca, disputeID, RULING_MERCHANT);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "payer should recover nothing"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT,
            "merchant should capture everything"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    function test_dispute_refundsOverpayment() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        ca.dispute{value: ARBITRATION_COST + 0.5 ether}(
            paymentHash,
            AMOUNT,
            AGREEMENT_URI
        );

        assertEq(
            payer.balance,
            1 ether - ARBITRATION_COST,
            "overpayment should be refunded"
        );
    }

    /// @dev The undisputed remainder is captured to the merchant the moment the dispute opens —
    ///      no ruling can award it elsewhere, so it does not wait for the arbitration.
    function test_dispute_capturesRemainderImmediately() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);

        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "remainder should be captured at dispute time"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + disputedAmount,
            "payer should recover the disputed amount"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "the ruling should not move the remainder again"
        );
    }

    /// @dev A full-amount dispute has no remainder: nothing is captured when it opens.
    function test_dispute_fullClaim_capturesNothingImmediately() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        _dispute(paymentInfo, AMOUNT);

        assertEq(
            token.balanceOf(merchant),
            0,
            "nothing should be captured for a full-amount dispute"
        );
    }

    /// @dev With a concession in place, only the truly undisputed part is captured early;
    ///      the locked refund stays in escrow for the payer.
    function test_dispute_remainderCaptureRespectsConcession() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 20e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        uint120 disputedAmount = 30e6;
        _dispute(paymentInfo, disputedAmount);

        assertEq(
            token.balanceOf(merchant),
            AMOUNT - conceded - disputedAmount,
            "only the remainder should be captured"
        );
        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "locked refund must stay in escrow until settlement"
        );
    }

    /// @dev The remainder capture takes the payment's fee like any other capture.
    function test_dispute_remainderCaptureAppliesFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        paymentInfo.feeReceiver = feeRecipient;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );

        _dispute(paymentInfo, 40e6);

        assertEq(
            token.balanceOf(feeRecipient),
            0.6e6,
            "fee should be 1% of the captured remainder"
        );
        assertEq(
            token.balanceOf(merchant),
            60e6 - 0.6e6,
            "merchant should get the remainder minus fee"
        );
    }

    function test_dispute_forwardsArbitrationFee() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        _dispute(paymentInfo, AMOUNT);

        assertEq(
            address(arbitrator).balance,
            ARBITRATION_COST,
            "arbitration fee should reach the arbitrator"
        );
        assertEq(address(ca).balance, 0, "authorizer should hold no ETH");
    }

    /// @dev A dispute sent with an oversized claim and excess ETH, after a lock is already in place,
    ///      must succeed: the claim is clamped and the overpayment refunded. This is the state a
    ///      payer lands in when the merchant's lock front-runs their dispute.
    function test_dispute_clampAndOverpaymentRefund_withConcession() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 30e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        ca.dispute{value: ARBITRATION_COST + 0.5 ether}(
            paymentHash,
            AMOUNT,
            AGREEMENT_URI
        );

        (, , , uint120 disputedAmount, , , , ) = ca.payments(paymentHash);
        assertEq(
            disputedAmount,
            AMOUNT - conceded,
            "claim should be clamped to the disputable amount"
        );
        assertEq(
            payer.balance,
            1 ether - ARBITRATION_COST,
            "overpayment should be refunded"
        );
        assertEq(address(ca).balance, 0, "authorizer should hold no ETH");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );
    }

    /// @dev The IArbitrableV2 events are the contract's bridge to the Kleros Court: pin them.
    function test_dispute_emitsDisputeEvents() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.DisputeOpened(paymentHash, 1, AMOUNT);
        vm.expectEmit(true, true, true, true, address(ca));
        emit IArbitrableV2.DisputeRequest(arbitrator, 1, 1, 0, "");
        ca.dispute{value: ARBITRATION_COST}(paymentHash, AMOUNT, AGREEMENT_URI);
    }

    function test_dispute_revert_payerOnly() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.expectRevert(KlerosCaptureAuthorizer.PayerOnly.selector);
        ca.dispute(paymentHash, AMOUNT, AGREEMENT_URI);
    }

    /// @dev The dispute window is [authorize, end): disputing exactly at the end must fail.
    function test_dispute_revert_windowClosed() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.warp(block.timestamp + DISPUTE_WINDOW);
        vm.prank(payer);
        vm.expectRevert(KlerosCaptureAuthorizer.DisputeWindowClosed.selector);
        ca.dispute(paymentHash, AMOUNT, AGREEMENT_URI);
    }

    function test_dispute_revert_zeroDisputedAmount() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.InvalidAmount.selector,
                0,
                AMOUNT
            )
        );
        ca.dispute(paymentHash, 0, AGREEMENT_URI);
    }

    /// @dev Claims above the authorized amount are clamped, not rejected: a too-large claim
    ///      must never cost the payer their dispute.
    function test_dispute_clampsDisputedAmountAboveMax() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        ca.dispute{value: ARBITRATION_COST}(
            paymentHash,
            AMOUNT + 1,
            AGREEMENT_URI
        );

        (, , , uint120 disputedAmount, , , , ) = ca.payments(paymentHash);
        assertEq(
            disputedAmount,
            AMOUNT,
            "claim should be clamped to the authorized amount"
        );
    }

    /// @dev The front-run defense: a concession raise can never invalidate a payer's in-flight
    ///      dispute. Disputing the full amount after a concession clamps to the disputable
    ///      remainder, and the payer still recovers everything on a win.
    function test_dispute_fullClaimAfterConcession_clampsAndRecoversAll()
        public
    {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 30e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        uint256 disputeID = _dispute(paymentInfo, AMOUNT);
        (, , , uint120 disputedAmount, , , , ) = ca.payments(paymentHash);
        assertEq(
            disputedAmount,
            AMOUNT - conceded,
            "claim should be clamped to the disputable amount"
        );

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "payer should recover everything"
        );
        assertEq(token.balanceOf(merchant), 0, "merchant should get nothing");
    }

    function test_dispute_revert_insufficientFee() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.InsufficientArbitrationFee.selector,
                ARBITRATION_COST - 1,
                ARBITRATION_COST
            )
        );
        ca.dispute{value: ARBITRATION_COST - 1}(
            paymentHash,
            AMOUNT,
            AGREEMENT_URI
        );
    }

    function test_dispute_revert_alreadyDisputed() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        _dispute(paymentInfo, AMOUNT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Authorized,
                KlerosCaptureAuthorizer.Status.Disputed
            )
        );
        ca.dispute(paymentHash, AMOUNT, AGREEMENT_URI);
    }

    /// @dev A hash nobody authorized has no stored payer, so nobody can dispute it.
    function test_dispute_revert_unknownPayment() public {
        vm.prank(payer);
        vm.expectRevert(KlerosCaptureAuthorizer.PayerOnly.selector);
        ca.dispute(keccak256("unknown"), AMOUNT, AGREEMENT_URI);
    }

    function test_dispute_revert_refundTransferFailed() public {
        RejectingPayer rejectingPayer = new RejectingPayer();
        token.mint(address(rejectingPayer), AMOUNT);

        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.payer = address(rejectingPayer);
        // The mock token accepts ERC-1271 signatures and RejectingPayer approves anything.
        ca.authorize(paymentInfo, AMOUNT, address(collector), "");
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            KlerosCaptureAuthorizer.ArbitrationFeeRefundFailed.selector
        );
        rejectingPayer.openDispute{value: ARBITRATION_COST + 0.1 ether}(
            ca,
            paymentHash,
            AMOUNT
        );
    }

    /// @dev The fee refund is the only external call to an untrusted address. State is final before it,
    ///      so a payer re-entering from the refund hook can neither open a second dispute nor settle.
    function test_dispute_storesAgreementURI() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        _dispute(paymentInfo, AMOUNT);

        (, , , , , , , string memory agreementURI) = ca.payments(paymentHash);
        assertEq(agreementURI, AGREEMENT_URI);
    }

    /// @dev A payer without our SDK may have nothing to pin: the dispute still opens, the jurors then
    ///      rely on evidence only.
    function test_dispute_acceptsEmptyAgreementURI() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        uint256 disputeID = ca.dispute{value: ARBITRATION_COST}(
            paymentHash,
            AMOUNT,
            ""
        );

        assertEq(ca.getCaseData(disputeID).agreementURI, "");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );
    }

    function test_dispute_reentrancyFromFeeRefundIsHarmless() public {
        ReentrantPayer reentrantPayer = new ReentrantPayer();
        token.mint(address(reentrantPayer), AMOUNT);

        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.payer = address(reentrantPayer);
        ca.authorize(paymentInfo, AMOUNT, address(collector), "");
        bytes32 paymentHash = _hash(paymentInfo);

        vm.deal(address(this), 1 ether);
        uint256 disputeID = reentrantPayer.openDispute{
            value: ARBITRATION_COST + 0.1 ether
        }(ca, paymentHash, AMOUNT);

        assertEq(reentrantPayer.failures(), 4, "every re-entry must revert");
        assertEq(
            address(reentrantPayer).balance,
            0.1 ether,
            "the overpayment must be refunded exactly once"
        );
        assertEq(disputeID, 1);
        assertEq(arbitrator.nextDisputeID(), 2, "exactly one dispute created");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );
        assertEq(ca.getCaseData(disputeID).paymentHash, paymentHash);
    }

    // ************************************* //
    // *               rule                * //
    // ************************************* //

    function test_rule_emitsRuling() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        uint256 disputeID = _dispute(paymentInfo, AMOUNT);

        vm.expectEmit(true, true, true, true, address(ca));
        emit IArbitrableV2.Ruling(arbitrator, disputeID, RULING_PAYER);
        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);
    }

    function test_rule_revert_arbitratorOnly() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        uint256 disputeID = _dispute(paymentInfo, AMOUNT);

        vm.expectRevert(KlerosCaptureAuthorizer.ArbitratorOnly.selector);
        ca.rule(disputeID, RULING_PAYER);
    }

    /// @dev The common case settles inside the arbitrator's transaction: no second call needed, and the
    ///      permissionless fallback then has nothing left to do.
    function test_rule_settlesInSameTransaction() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint256 disputeID = _dispute(paymentInfo, AMOUNT);

        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.RulingExecuted(paymentHash, RULING_PAYER);
        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "payer should be refunded in the ruling transaction"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Resolved,
                KlerosCaptureAuthorizer.Status.Voided
            )
        );
        ca.executeRuling(paymentHash);
    }

    /// @dev When settlement cannot go through in the ruling transaction, here because the authorization
    ///      expired and the escrow refuses the capture, the ruling is still recorded, the arbitrator's
    ///      transaction still succeeds, and the payment is left for the permissionless fallback.
    function test_rule_defersSettlementWhenItFails() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint256 disputeID = _dispute(paymentInfo, AMOUNT);

        vm.warp(paymentInfo.authorizationExpiry);
        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.SettlementDeferred(
            paymentHash,
            RULING_MERCHANT
        );
        arbitrator.giveRuling(ca, disputeID, RULING_MERCHANT);

        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Resolved),
            "ruling must be recorded"
        );
        assertEq(token.balanceOf(merchant), 0, "nothing should have moved");

        // The fallback stays open; here it still fails for the same reason, which is the escrow's call.
        vm.expectRevert();
        ca.executeRuling(paymentHash);
    }

    /// @dev A settlement that fails inside `rule` for a transient reason must still complete later
    ///      through the permissionless fallback, with the ruling recorded in between.
    function test_rule_deferredSettlementSucceedsLater() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "remainder captured at dispute time"
        );

        // Make every token transfer revert, as a paused or blacklisting token would.
        vm.mockCallRevert(
            address(token),
            abi.encodeWithSelector(IERC20.transfer.selector),
            "token paused"
        );
        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.SettlementDeferred(
            paymentHash,
            RULING_MERCHANT
        );
        arbitrator.giveRuling(ca, disputeID, RULING_MERCHANT);
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Resolved),
            "ruling recorded, not settled"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "nothing moved while paused"
        );

        vm.clearMockedCalls();
        ca.executeRuling(paymentHash);

        assertEq(
            token.balanceOf(merchant),
            AMOUNT,
            "fallback should complete the merchant win"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    // ************************************* //
    // *          executeRuling            * //
    // ************************************* //

    /// @dev Default policy: refuse-to-arbitrate is treated as a merchant win, everything captured.
    function test_refuseToArbitrate_merchantPolicy_capturesAll() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        uint256 disputeID = _dispute(paymentInfo, 30e6);

        arbitrator.giveRuling(ca, disputeID, RULING_REFUSED);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "payer should recover nothing"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT,
            "merchant should capture everything"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    /// @dev Refuse-to-arbitrate with the policy flag favoring the payer must mirror a payer win:
    ///      only the disputed amount returns, the conceded remainder is captured to the merchant.
    function test_refuseToArbitrate_payerPolicy_splitsLikePayerWin() public {
        ca = new KlerosCaptureAuthorizer({
            _escrow: escrow,
            _arbitrator: arbitrator,
            _arbitratorExtraData: "",
            _disputeWindow: DISPUTE_WINDOW,
            _arbitrationBuffer: ARBITRATION_BUFFER,
            _refuseToArbitrateCapturesToMerchant: false,
            _templateRegistry: templateRegistry,
            _templateData: TEMPLATE_DATA,
            _templateDataMappings: TEMPLATE_MAPPINGS
        });

        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();

        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);

        arbitrator.giveRuling(ca, disputeID, RULING_REFUSED);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + disputedAmount,
            "payer should recover only the disputed amount"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - disputedAmount,
            "merchant should keep the conceded remainder"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev Conceded + max disputable = the full payment: a payer win over the remainder recovers everything.
    function test_concessionPlusDispute_payerWins_recoversAll() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 30e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        uint256 disputeID = _dispute(paymentInfo, AMOUNT - conceded);
        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "payer should recover everything"
        );
        assertEq(token.balanceOf(merchant), 0, "merchant should get nothing");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev Even winning the dispute does not claw back the concession.
    function test_concession_survivesMerchantWin() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 30e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        uint256 disputeID = _dispute(paymentInfo, AMOUNT - conceded);
        arbitrator.giveRuling(ca, disputeID, RULING_MERCHANT);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + conceded,
            "payer should still get the concession"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - conceded,
            "merchant should capture only the unlocked amount"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    /// @dev Three-way split: concession to the payer, disputed amount won by the payer,
    ///      undisputed remainder captured to the merchant.
    function test_concession_partialDispute_payerWins_threeWaySplit() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 20e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);
        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + conceded + disputedAmount,
            "payer should get the concession plus the disputed amount"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - conceded - disputedAmount,
            "merchant should keep the remainder"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev The ruling-time capture takes the payment's fee, same as every other capture.
    function test_executeRuling_merchantWinCaptureAppliesFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.minFeeBps = 100; // 1%
        paymentInfo.maxFeeBps = 100;
        paymentInfo.feeReceiver = feeRecipient;
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );

        uint120 disputedAmount = 40e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);
        arbitrator.giveRuling(ca, disputeID, RULING_MERCHANT);

        assertEq(
            token.balanceOf(feeRecipient),
            1e6,
            "fee should be 1% of both captures combined"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - 1e6,
            "merchant should get everything minus the fee"
        );
    }

    function test_executeRuling_revert_notResolved() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Resolved,
                KlerosCaptureAuthorizer.Status.Authorized
            )
        );
        ca.executeRuling(paymentHash);
    }

    // ************************************* //
    // *          merchantRefund           * //
    // ************************************* //

    function test_merchantRefund_full_settlesImmediately() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(merchant);
        ca.merchantRefund(paymentHash, AMOUNT);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "payer should be fully refunded"
        );
        assertEq(token.balanceOf(merchant), 0, "merchant should keep nothing");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev A partial concession moves no funds and keeps the payment disputable; it is paid out
    ///      when the unchallenged capture settles the payment.
    function test_merchantRefund_partial_paysOutAtCapture() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        uint120 conceded = 40e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "no funds should move yet"
        );
        assertEq(token.balanceOf(merchant), 0, "no funds should move yet");
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Authorized)
        );

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHash);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT + conceded,
            "payer should get the concession"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT - conceded,
            "merchant should keep the remainder"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    function test_merchantRefund_raisableUpToFull() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(merchant);
        ca.merchantRefund(paymentHash, 25e6);
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, 30e6);
        assertEq(
            ca.maxDisputable(paymentHash),
            AMOUNT - 30e6,
            "the raise should replace the concession, not add"
        );

        vm.prank(merchant);
        ca.merchantRefund(paymentHash, AMOUNT);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE,
            "reaching a full concession should settle immediately"
        );
        assertEq(
            uint256(_status(paymentInfo)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }

    /// @dev The concession is a ratchet: the payer may rely on it when deciding not to dispute,
    ///      so the merchant can never lower it.
    function test_merchantRefund_revert_cannotLower() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(merchant);
        ca.merchantRefund(paymentHash, 30e6);

        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.RefundNotIncreased.selector,
                30e6,
                10e6
            )
        );
        ca.merchantRefund(paymentHash, 10e6);

        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.RefundNotIncreased.selector,
                30e6,
                30e6
            )
        );
        ca.merchantRefund(paymentHash, 30e6);
    }

    function test_merchantRefund_revert_receiverOnly() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(payer);
        vm.expectRevert(KlerosCaptureAuthorizer.ReceiverOnly.selector);
        ca.merchantRefund(paymentHash, AMOUNT);
    }

    /// @dev A hash nobody authorized has no stored receiver, so nobody can concede on it.
    function test_merchantRefund_revert_unknownPayment() public {
        vm.prank(merchant);
        vm.expectRevert(KlerosCaptureAuthorizer.ReceiverOnly.selector);
        ca.merchantRefund(keccak256("unknown"), AMOUNT);
    }

    function test_merchantRefund_revert_invalidAmounts() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.RefundNotIncreased.selector,
                0,
                0
            )
        );
        ca.merchantRefund(paymentHash, 0);

        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.InvalidAmount.selector,
                AMOUNT + 1,
                AMOUNT
            )
        );
        ca.merchantRefund(paymentHash, AMOUNT + 1);
    }

    function test_merchantRefund_revert_afterDispute() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        _dispute(paymentInfo, 30e6);

        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.PaymentNotInState.selector,
                KlerosCaptureAuthorizer.Status.Authorized,
                KlerosCaptureAuthorizer.Status.Disputed
            )
        );
        ca.merchantRefund(paymentHash, 30e6);
    }

    function test_maxDisputable_tracksConcession() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        assertEq(
            ca.maxDisputable(paymentHash),
            AMOUNT,
            "initially the full authorized amount is disputable"
        );

        vm.prank(merchant);
        ca.merchantRefund(paymentHash, 30e6);
        assertEq(
            ca.maxDisputable(paymentHash),
            AMOUNT - 30e6,
            "the concession should shrink the disputable amount"
        );
    }

    function test_merchantRefund_emitsMerchantRefunded() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);

        vm.expectEmit(true, true, true, true, address(ca));
        emit KlerosCaptureAuthorizer.MerchantRefunded(paymentHash, 40e6);
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, 40e6);
    }

    // ************************************* //
    // *            getCaseData            * //
    // ************************************* //

    /// @dev What a dispute template reads through its data mapping: one call, all the facts.
    function test_getCaseData_returnsCaseFacts() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _authorize();
        bytes32 paymentHash = _hash(paymentInfo);
        uint120 conceded = 20e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHash, conceded);
        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfo, disputedAmount);

        KlerosCaptureAuthorizer.CaseData memory data = ca.getCaseData(
            disputeID
        );
        assertEq(data.paymentHash, paymentHash);
        assertEq(data.payer, payer);
        assertEq(data.receiver, merchant);
        assertEq(data.token, address(token));
        assertEq(data.authorizedAmount, AMOUNT);
        assertEq(data.disputedAmount, disputedAmount);
        assertEq(data.lockedRefundAmount, conceded);
        assertEq(
            uint256(data.status),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );
        assertEq(data.ruling, 0);
        assertEq(data.agreementURI, AGREEMENT_URI);
        assertEq(data.salt, bytes32(paymentInfo.salt));

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);
        data = ca.getCaseData(disputeID);
        assertEq(
            uint256(data.status),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
        assertEq(data.ruling, RULING_PAYER);
        assertEq(
            data.agreementURI,
            AGREEMENT_URI,
            "URI must outlive the ruling"
        );
    }

    /// @dev With our SDK the salt is the keccak256 of the agreement. The Court gets it back as bytes32,
    ///      the same form a juror obtains by hashing the linked file.
    function test_getCaseData_returnsAgreementHashAsSalt() public {
        bytes32 agreementHash = keccak256(
            '{"resource":{"url":"https://api.example/report"},"accepts":[]}'
        );
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();
        paymentInfo.salt = uint256(agreementHash);
        ca.authorize(
            paymentInfo,
            AMOUNT,
            address(collector),
            _sign(paymentInfo)
        );
        uint256 disputeID = _dispute(paymentInfo, AMOUNT);

        KlerosCaptureAuthorizer.CaseData memory data = ca.getCaseData(
            disputeID
        );
        assertEq(data.salt, agreementHash);
        assertEq(
            uint256(data.salt),
            ca.getPaymentInfo(data.paymentHash).salt,
            "case salt must be the stored PaymentInfo.salt"
        );
        assertTrue(
            data.salt != data.paymentHash,
            "salt is not the payment hash"
        );
    }

    function test_getCaseData_revert_unknownDispute() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KlerosCaptureAuthorizer.UnknownDispute.selector,
                999
            )
        );
        ca.getCaseData(999);
    }

    // ************************************* //
    // *              charge               * //
    // ************************************* //

    function test_charge_reverts() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfo = _paymentInfo();

        vm.expectRevert(KlerosCaptureAuthorizer.ChargeDisabled.selector);
        ca.charge(paymentInfo, AMOUNT, address(collector), "", 0, address(0));
    }

    // ************************************* //
    // *        Concurrent Payments        * //
    // ************************************* //

    /// @dev Rulings must route to their own payment when two disputes are live at once.
    function test_concurrentPayments_rulingsRouteIndependently() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfoA = _paymentInfo();
        AuthCaptureEscrow.PaymentInfo memory paymentInfoB = _paymentInfo();
        paymentInfoB.salt = 2;
        ca.authorize(
            paymentInfoA,
            AMOUNT,
            address(collector),
            _sign(paymentInfoA)
        );
        ca.authorize(
            paymentInfoB,
            AMOUNT,
            address(collector),
            _sign(paymentInfoB)
        );

        uint256 disputeA = _dispute(paymentInfoA, AMOUNT);
        uint256 disputeB = _dispute(paymentInfoB, 30e6);

        arbitrator.giveRuling(ca, disputeA, RULING_PAYER);
        arbitrator.giveRuling(ca, disputeB, RULING_MERCHANT);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - AMOUNT,
            "payer should recover A in full and lose B"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT,
            "merchant should capture only B"
        );
        assertEq(
            uint256(_status(paymentInfoA)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
        assertEq(
            uint256(_status(paymentInfoB)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );
    }

    /// @dev Mixed lifecycles must stay isolated: a concession and dispute on payment A must not
    ///      leak into sibling payment B, which settles by plain unchallenged capture.
    function test_concurrentPayments_mixedLifecyclesStayIsolated() public {
        AuthCaptureEscrow.PaymentInfo memory paymentInfoA = _paymentInfo();
        AuthCaptureEscrow.PaymentInfo memory paymentInfoB = _paymentInfo();
        paymentInfoB.salt = 2;
        ca.authorize(
            paymentInfoA,
            AMOUNT,
            address(collector),
            _sign(paymentInfoA)
        );
        bytes32 paymentHashA = _hash(paymentInfoA);
        ca.authorize(
            paymentInfoB,
            AMOUNT,
            address(collector),
            _sign(paymentInfoB)
        );
        bytes32 paymentHashB = _hash(paymentInfoB);

        uint120 conceded = 20e6;
        vm.prank(merchant);
        ca.merchantRefund(paymentHashA, conceded);
        assertEq(
            ca.maxDisputable(paymentHashA),
            AMOUNT - conceded,
            "concession should apply to A"
        );
        assertEq(
            ca.maxDisputable(paymentHashB),
            AMOUNT,
            "concession on A should not leak into B"
        );

        uint120 disputedAmount = 30e6;
        uint256 disputeID = _dispute(paymentInfoA, disputedAmount);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        ca.captureIfUnchallenged(paymentHashB);
        assertEq(
            token.balanceOf(merchant),
            AMOUNT + AMOUNT - conceded - disputedAmount,
            "all of B plus A's remainder, captured when A's dispute opened"
        );
        assertEq(
            uint256(_status(paymentInfoA)),
            uint256(KlerosCaptureAuthorizer.Status.Disputed)
        );
        assertEq(
            uint256(_status(paymentInfoB)),
            uint256(KlerosCaptureAuthorizer.Status.Captured)
        );

        arbitrator.giveRuling(ca, disputeID, RULING_PAYER);

        assertEq(
            token.balanceOf(payer),
            PAYER_BALANCE - 2 * AMOUNT + conceded + disputedAmount,
            "payer should recover A's concession plus disputed amount, nothing from B"
        );
        assertEq(
            token.balanceOf(merchant),
            AMOUNT + AMOUNT - conceded - disputedAmount,
            "merchant should get all of B plus A's remainder"
        );
        assertEq(
            uint256(_status(paymentInfoA)),
            uint256(KlerosCaptureAuthorizer.Status.Voided)
        );
    }
}
