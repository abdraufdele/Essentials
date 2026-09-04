// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {HookMiner} from "../test/utils/HookMiner.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice Deploys EssentialsHook to whatever chain `--rpc-url` points at,
/// mining a CREATE2 salt so the deployed address encodes the required
/// permission flags.
contract DeployEssentialsHook is Script {
    // forge-std's Script base already declares CREATE2_FACTORY with this
    // exact value -- the canonical CREATE2 deployer proxy
    // `forge script --broadcast` actually routes salted `new X{salt:}()`
    // calls through, on any chain that has it deployed (essentially all
    // production chains and local anvil). HookMiner must mine against
    // THIS address, not the broadcasting EOA -- confirmed the hard way
    // while building the live demo scripts (script/demo/): mining
    // against msg.sender compiles fine but reverts on the very first
    // real broadcast, since the deployment that actually happens goes
    // through this factory instead.
    //address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDdFA3Aa6fA03408;
    address constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run(address poolManager) external returns (EssentialsHook hook) {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(EssentialsHook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new EssentialsHook{salt: salt}(IPoolManager(poolManager));
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployEssentialsHook: address mismatch");
        console2.log("EssentialsHook deployed at:", address(hook));
    }
}
