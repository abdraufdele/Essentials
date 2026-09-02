// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * LIVE DEMO — Phase 1: deploy + queue a sandwich attempt
 *
 * Runs against a real local anvil chain (not a dry-run simulation) so the
 * batch-clearing mechanism can actually be watched happening across real,
 * separate, block-mined transactions — this is the "small script showing
 * attacker attempted a sandwich -> got taxed -> victim got partially
 * refunded, in real time on a local fork" deliverable.
 *
 * Usage (see script/demo/run_local_demo.sh for the full orchestrated
 * version — this file can also be run manually):
 *
 *   anvil                                  # terminal 1, leave running
 *   forge script script/demo/DemoPart1_SetupAndQueue.s.sol \
 *     --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
 *
 * Uses anvil's well-known default funded accounts (#0 deployer, #1
 * attacker, #2 victim) so this runs with zero setup against a fresh
 * anvil instance -- these are publicly known test-only keys, never use
 * them for anything real.
 */
import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "../../test/utils/HookMiner.sol";
import {EssentialsHook} from "../../src/EssentialsHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

contract DemoPart1_SetupAndQueue is Script {
    using PoolIdLibrary for PoolKey;

    // anvil's default account #0 / #1 / #2 private keys — well-known,
    // test-only, funded automatically on a fresh anvil instance.
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ATTACKER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690;
    uint256 constant VICTIM_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365;

    function run() external {
        address deployer = vm.addr(DEPLOYER_PK);
        address attacker = vm.addr(ATTACKER_PK);
        address victim = vm.addr(VICTIM_PK);

        console2.log("=== Essentials live demo: Phase 1 (setup + queue a sandwich attempt) ===");
        console2.log("deployer:", deployer);
        console2.log("attacker:", attacker);
        console2.log("victim:  ", victim);

        vm.startBroadcast(DEPLOYER_PK);

        PoolManager manager = new PoolManager(deployer);
        console2.log("PoolManager deployed:", address(manager));

        MockERC20 token0 = new MockERC20("Demo Token0", "TKN0", 18);
        MockERC20 token1 = new MockERC20("Demo Token1", "TKN1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        console2.log("token0:", address(token0));
        console2.log("token1:", address(token1));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager);
        // forge-std's Script base declares CREATE2_FACTORY with exactly
        // this value already -- forge script routes salted
        // `new X{salt:}()` calls through this canonical factory when
        // broadcasting, not through the deployer EOA directly. HookMiner
        // must mine against the same address the real deployment will
        // actually use, or the mined salt targets the wrong address and
        // the real deployment reverts inside
        // Hooks.validateHookPermissions. Confirmed the hard way: an
        // earlier version of this script mined against the deployer EOA
        // instead and reverted on the very first real broadcast.
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(EssentialsHook).creationCode, constructorArgs);
        EssentialsHook hook = new EssentialsHook{salt: salt}(manager);
        require(address(hook) == hookAddress, "hook address mismatch");
        console2.log("EssentialsHook deployed:", address(hook));

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 for 1:1

        token0.mint(deployer, 2_000 ether);
        token1.mint(deployer, 2_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                // liquidityDelta is a Uniswap "L" (sqrt-price-space) unit,
                // NOT a raw token amount -- convert from a desired real
                // token depth via LiquidityAmounts, the same way
                // Deployers.seedMoreLiquidity does in the test suite.
                // Passing a raw ether-scale number directly here (an
                // earlier version of this script did) silently creates a
                // position with far less real depth than intended, and
                // the first queued swap below reverts on insufficient
                // pool balance.
                liquidityDelta: int256(
                    uint256(
                        LiquidityAmounts.getLiquidityForAmounts(
                            79228162514264337593543950336,
                            TickMath.getSqrtPriceAtTick(-600),
                            TickMath.getSqrtPriceAtTick(600),
                            300 ether,
                            300 ether
                        )
                    )
                ),
                salt: 0
            }),
            ""
        );
        console2.log("seeded pool liquidity");

        // fund attacker/victim with ETH for gas -- don't assume the
        // ATTACKER_PK/VICTIM_PK constants above happen to match whatever
        // this specific anvil instance's pre-funded default accounts are;
        // confirmed the hard way that they didn't. This works regardless.
        (bool sentA,) = payable(attacker).call{value: 5 ether}("");
        require(sentA, "fund attacker failed");
        (bool sentV,) = payable(victim).call{value: 5 ether}("");
        require(sentV, "fund victim failed");

        // mint directly to attacker/victim here (MockERC20.mint is
        // public) rather than having them mint to themselves later --
        // every setup transaction needs to land BEFORE the front-run
        // swap below, not interleaved between the three swaps that are
        // meant to share one batch. See the note further down: with
        // anvil auto-mining one block per transaction, anything that
        // lands *between* the front-run and back-run pushes them past
        // MIN_WINDOW_BLOCKS and the batch settles early -- confirmed the
        // hard way when mint/approve calls were originally interleaved
        // between the three swaps here.
        token0.mint(attacker, 100 ether);
        token1.mint(attacker, 100 ether);
        token0.mint(victim, 100 ether);

        vm.stopBroadcast();

        // --- attacker's approvals (must come from the attacker's own
        // key, but still land safely before the front-run swap) ---
        vm.startBroadcast(ATTACKER_PK);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopBroadcast();

        // --- victim's approval, same reasoning ---
        vm.startBroadcast(VICTIM_PK);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.stopBroadcast();

        // --- the three swaps that share one batch: front-run, victim,
        // back-run, with NOTHING else broadcast in between ---
        vm.startBroadcast(ATTACKER_PK);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -20 ether, sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(attacker)
        );
        console2.log("[block %s] attacker queued front-run: sell 20 TKN0", block.number);
        vm.stopBroadcast();

        // --- victim's ordinary swap, landing in the same batch ---
        vm.startBroadcast(VICTIM_PK);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(victim)
        );
        console2.log("[block %s] victim queued: sell 5 TKN0", block.number);
        vm.stopBroadcast();

        // --- attacker back-run, in the SAME batch as the victim ---
        vm.startBroadcast(ATTACKER_PK);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -20 ether,
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(attacker)
        );
        console2.log("[block %s] attacker queued back-run: sell 20 TKN1", block.number);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Queue is now: front-run, victim, back-run -- same batch, ordering irrelevant.");
        console2.log("Save these addresses, then run DemoPart2_MineAndSettle.s.sol:");
        console2.log("  MANAGER=%s", address(manager));
        console2.log("  HOOK=%s", address(hook));
        console2.log("  TOKEN0=%s", address(token0));
        console2.log("  TOKEN1=%s", address(token1));
    }
}
