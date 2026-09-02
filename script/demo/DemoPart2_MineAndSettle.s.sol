// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * LIVE DEMO — Phase 2: mine forward, settle, report the real result
 *
 * Reads the contracts DemoPart1_SetupAndQueue.s.sol deployed (pass their
 * addresses as env vars — Part 1 prints the exact export lines to use),
 * advances the real anvil chain past the batch window, settles it for
 * real, and prints the attacker's real loss and the victim's real fill
 * straight from on-chain balances.
 *
 * Usage:
 *   MANAGER=0x... HOOK=0x... TOKEN0=0x... TOKEN1=0x... \
 *     forge script script/demo/DemoPart2_MineAndSettle.s.sol \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 */
import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EssentialsHook} from "../../src/EssentialsHook.sol";

contract DemoPart2_MineAndSettle is Script {
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ATTACKER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690;
    uint256 constant VICTIM_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365;

    function run() external {
        EssentialsHook hook = EssentialsHook(vm.envAddress("HOOK"));
        MockERC20 token0 = MockERC20(vm.envAddress("TOKEN0"));
        MockERC20 token1 = MockERC20(vm.envAddress("TOKEN1"));
        address attacker = vm.addr(ATTACKER_PK);
        address victim = vm.addr(VICTIM_PK);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        EssentialsHook.BatchState memory before = hook.getBatch(key);
        console2.log("=== Essentials live demo: Phase 2 (mine forward, settle, report) ===");
        console2.log("current block:", block.number);
        console2.log("batch startBlock:", before.startBlock);
        console2.log("batch windowBlocks:", before.windowBlocks);
        console2.log("orders queued:", hook.getQueueLength(key));

        uint256 targetBlock = before.startBlock + before.windowBlocks + 1;
        require(
            block.number >= targetBlock,
            "Batch window hasn't elapsed on-chain yet -- run `cast rpc anvil_mine <N> --rpc-url <RPC>` first (vm.roll only affects this script's own simulation pass, not the real chain; see script/demo/run_local_demo.sh)"
        );

        uint256 attackerToken0Before = token0.balanceOf(attacker);
        uint256 attackerToken1Before = token1.balanceOf(attacker);
        uint256 victimToken1Before = token1.balanceOf(victim);

        vm.startBroadcast(DEPLOYER_PK);
        hook.settleBatch(key);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== SETTLED at block %s ===", block.number);

        uint256 attackerToken0After = token0.balanceOf(attacker);
        uint256 attackerToken1After = token1.balanceOf(attacker);
        uint256 victimToken1After = token1.balanceOf(victim);

        // attacker spent 20 TKN0 (front-run) + 20 TKN1 (back-run); this is
        // their net position change across both legs, token0-equivalent
        // at ~pool price.
        int256 attackerPnl = (int256(attackerToken0After) - int256(attackerToken0Before) - 20 ether)
            + (int256(attackerToken1After) - int256(attackerToken1Before) - 20 ether);

        console2.log("attacker net P&L across both legs (wei, token0-equivalent):");
        console2.logInt(attackerPnl);
        if (attackerPnl < 0) {
            console2.log(">>> attacker LOST money attempting the sandwich <<<");
        } else {
            console2.log(">>> attacker profited (unexpected on the hooked pool) <<<");
        }

        console2.log("");
        console2.log("victim TKN1 received:", victimToken1After - victimToken1Before);
        console2.log("victim sold 5 TKN0 -- a fair fill is close to 5 TKN1 at this pool's ~1:1 price.");

        require(hook.getQueueLength(key) == 0, "batch should be fully cleared");
        console2.log("");
        console2.log("Queue is empty. Batch fully settled. This all happened across real,");
        console2.log("separately-mined blocks on a real local anvil chain -- not a dry-run test.");
    }
}
