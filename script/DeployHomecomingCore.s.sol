// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {HomecomingHook} from "../src/HomecomingHook.sol";
import {HomecomingTypes} from "../src/libraries/HomecomingTypes.sol";

/// @notice Deploys Homecoming Core (HomecomingHook) — intended for Unichain Sepolia (chain id
/// 1301), but reads the PoolManager address from `hookmate`'s AddressConstants for whatever chain
/// it's run against, so the same script also works for local/other-testnet dry runs.
///
/// @dev Requires the standard deterministic CREATE2 deployer proxy
/// (0x4e59b44847b379578588920cA78FbF26c0B4956C) to already be present on the target chain — it is
/// on essentially every EVM chain, including Unichain Sepolia, as a system-level pre-deploy. This
/// is the same proxy HookMiner's own NatSpec names as required for `forge script` deployments (as
/// opposed to `forge test`, where the test contract itself can execute CREATE2 directly).
///
/// venueAdapter is deliberately left unset (address(0)) — see HomecomingHook's NatSpec on why that
/// is the honest default for this chain (no real synchronous venue exists to configure).
contract DeployHomecomingCore is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (HomecomingHook hook) {
        address poolManager = AddressConstants.getPoolManagerAddress(block.chainid);
        address governance = msg.sender;

        HomecomingTypes.Config memory cfg = HomecomingTypes.Config({
            minAmountIn: 1e15,
            minLiquidity: 0,
            lpRecaptureBps: 5000,
            maxImprovementBpsOfAmountIn: 1000
        });

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), cfg, governance);
        bytes memory creationCode = type(HomecomingHook).creationCode;

        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        vm.startBroadcast();
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode, constructorArgs));
        require(ok, "CREATE2 deployment call failed");
        vm.stopBroadcast();

        require(predicted.code.length != 0, "no code at predicted hook address after deployment");
        hook = HomecomingHook(predicted);

        console2.log("Chain ID:", block.chainid);
        console2.log("PoolManager:", poolManager);
        console2.log("HomecomingHook deployed at:", address(hook));
        console2.log("Governance:", governance);
        console2.log("venueAdapter (should be address(0) on a real deployment):", address(hook.venueAdapter()));
    }
}
