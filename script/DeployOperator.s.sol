// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AuthCaptureEscrow} from "commerce-payments/src/AuthCaptureEscrow.sol";
import {IArbitratorV2} from "../src/interfaces/IArbitratorV2.sol";
import {IDisputeTemplateRegistry} from "../src/interfaces/IDisputeTemplateRegistry.sol";
import {KlerosCaptureAuthorizer} from "../src/KlerosCaptureAuthorizer.sol";

/// @notice Deploys the Kleros operator against the escrow copy and the Kleros Court v2 on Arbitrum Sepolia,
///         registering the dispute template from `template/` in the constructor.
/// @dev forge script script/DeployOperator.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --account <name> --broadcast
contract DeployOperator is Script {
    // Deployment inputs.
    address constant ESCROW = 0x3e1e17725899ce96AF5C95b9f95a9c74588cf622; // Our AuthCaptureEscrow deployment on Arbitrum Sepolia.
    uint256 constant DISPUTE_WINDOW = 10 minutes; // Test value, so every demo path completes within the hour. A real deployment gives the payer days.
    uint256 constant ARBITRATION_BUFFER = 7 days;
    bool constant REFUSE_TO_ARBITRATE_TO_MERCHANT = true;

    /// @dev Kleros Court v2 on Arbitrum Sepolia (kleros-v2 contracts/deployments/arbitrumSepolia/*.json).
    address constant KLEROS_CORE = 0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479;
    address constant TEMPLATE_REGISTRY =
        0xe763d31Cb096B4bc7294012B78FC7F148324ebcb;
    uint256 constant AGENTIC_COMMERCE_COURT = 8;
    /// @dev KlerosCore defaults (src/libraries/Constants.sol): three jurors, classic dispute kit.
    uint256 constant MIN_JURORS = 3;
    uint256 constant DISPUTE_KIT_CLASSIC = 1;

    function run() public {
        string memory templateData = vm.readFile(
            "template/dispute-template.json"
        );
        string memory templateDataMappings = vm.readFile(
            "template/data-mappings.json"
        );
        // KlerosCore reads (courtID, minJurors, disputeKitID) from the first three words of extraData.
        bytes memory extraData = abi.encode(
            AGENTIC_COMMERCE_COURT,
            MIN_JURORS,
            DISPUTE_KIT_CLASSIC
        );

        vm.startBroadcast();
        KlerosCaptureAuthorizer operator = new KlerosCaptureAuthorizer(
            AuthCaptureEscrow(ESCROW),
            IArbitratorV2(KLEROS_CORE),
            extraData,
            DISPUTE_WINDOW,
            ARBITRATION_BUFFER,
            REFUSE_TO_ARBITRATE_TO_MERCHANT,
            IDisputeTemplateRegistry(TEMPLATE_REGISTRY),
            templateData,
            templateDataMappings
        );
        vm.stopBroadcast();

        console2.log("KlerosCaptureAuthorizer:", address(operator));
        console2.log("templateId:", operator.templateId());
    }
}
