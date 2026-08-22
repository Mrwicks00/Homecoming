// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {CowRecaptureReceiver} from "../src/integrations/cow/CowRecaptureReceiver.sol";
import {HooksTrampoline} from "../src/integrations/cow/vendor/HooksTrampoline.sol";
import {HomecomingTypes} from "../src/libraries/HomecomingTypes.sol";

/// @notice Deploys the real CoW leg — intended for Ethereum Sepolia (chain id 11155111), the one
/// chain where both canonical CoW Protocol and Uniswap v4-core are actually deployed
/// (FEASIBILITY.md). Deploys a fresh HooksTrampoline pointed at CoW's real, canonical
/// GPv2Settlement, plus CowRecaptureReceiver. Neither requires CREATE2 mining — unlike
/// HomecomingHook, this is not a v4 hook and has no address-encoded permission flags.
contract DeployCowLeg is Script {
    /// @dev CoW Protocol's canonical GPv2Settlement on Ethereum Sepolia.
    /// Source: https://docs.cow.fi/cow-protocol/reference/contracts/core
    address constant GPV2_SETTLEMENT_SEPOLIA = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    function run() external returns (CowRecaptureReceiver receiver, HooksTrampoline trampoline) {
        address poolManager = AddressConstants.getPoolManagerAddress(block.chainid);
        address governance = msg.sender;

        HomecomingTypes.Config memory cfg = HomecomingTypes.Config({
            minAmountIn: 1e15,
            minLiquidity: 0,
            lpRecaptureBps: 5000,
            maxImprovementBpsOfAmountIn: 1000
        });

        vm.startBroadcast();
        trampoline = new HooksTrampoline(GPV2_SETTLEMENT_SEPOLIA);
        receiver = new CowRecaptureReceiver(IPoolManager(poolManager), cfg, governance);
        vm.stopBroadcast();

        console2.log("Chain ID:", block.chainid);
        console2.log("PoolManager:", poolManager);
        console2.log("GPv2Settlement:", GPV2_SETTLEMENT_SEPOLIA);
        console2.log("HooksTrampoline deployed at:", address(trampoline));
        console2.log("CowRecaptureReceiver deployed at:", address(receiver));
        console2.log("Governance:", governance);
        console2.log(
            "NOTE: point a CoW order's post-hook at (target = receiver, callData = recapture(...)), "
            "and route the order's own `receiver` field to the trader's own wallet, NOT this contract "
            "-- see CowRecaptureReceiver.sol NatSpec."
        );
    }
}
