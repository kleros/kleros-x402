// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AuthCaptureEscrow} from "commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "commerce-payments/src/collectors/ERC3009PaymentCollector.sol";

/// @notice Deploys a copy of the commerce-payments v1.1 escrow and its ERC-3009 collector on a chain where the
///         canonical set is not deployed (Arbitrum Sepolia).
/// @dev forge script script/DeployEscrow.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --account <name> --broadcast
contract DeployEscrow is Script {
    /// @dev Canonical Multicall3, same address on every chain. The collector needs it.
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    function run() public {
        vm.startBroadcast();
        AuthCaptureEscrow escrow = new AuthCaptureEscrow();
        ERC3009PaymentCollector collector = new ERC3009PaymentCollector(
            address(escrow),
            MULTICALL3
        );
        vm.stopBroadcast();

        console2.log("AuthCaptureEscrow:", address(escrow));
        console2.log("ERC3009PaymentCollector:", address(collector));
    }
}
