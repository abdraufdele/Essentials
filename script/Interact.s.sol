// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * INTERACT — a general-purpose console for a deployed EssentialsHook.
 *
 * Unlike script/demo/DemoPart1_SetupAndQueue.s.sol (which walks through
 * one fixed sandwich scenario end to end), this script exposes small,
 * independent, callable actions against an ALREADY-deployed hook/pool —
 * for poking at a local anvil deployment, a testnet deployment, or for
 * building a quick custom demo without writing a new script each time.
 *
 * Pool identity is read from env vars (same pattern as
 * script/demo/DemoPart2_MineAndSettle.s.sol):
 *
 *   HOOK=0x...          deployed EssentialsHook address
 *   TOKEN0=0x...         currency0 (must be < TOKEN1 numerically)
 *   TOKEN1=0x...         currency1
 *   FEE=3000             (optional, default 3000)
 *   TICK_SPACING=60       (optional, default 60)
 *
 * Usage examples (against a local anvil node):
 *
 *   # just look at current batch state, no broadcast needed
 *   HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. \
 *     forge script script/Interact.s.sol --sig "status()" --rpc-url $RPC
 *
 *   # queue a swap as the caller (needs PRIVATE_KEY + prior token approval)
 *   HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. PRIVATE_KEY=0x.. \
 *     forge script script/Interact.s.sol \
 *     --sig "queueSwap(bool,uint256)" true 1000000000000000000 \
 *     --rpc-url $RPC --broadcast
 *
 *   # settle once ready (needs --private-key or PRIVATE_KEY env; any
 *   # account works, settleBatch is permissionless)
 *   HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. \
 *     forge script script/Interact.s.sol --sig "settle()" \
 *     --rpc-url $RPC --private-key $PK --broadcast
 *
 *   # add / remove liquidity
 *   HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. PRIVATE_KEY=0x.. \
 *     forge script script/Interact.s.sol \
 *     --sig "addLiquidity(int24,int24,int256)" -600 600 1000000000000000000 \
 *     --rpc-url $RPC --broadcast
 *
 * See the Makefile for wrapper targets (`make status`, `make queue-swap`,
 * `make settle`, `make add-liquidity`, `make remove-liquidity`).
 */
import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {EssentialsHook} from "../src/EssentialsHook.sol";

contract Interact is Script {
    using PoolIdLibrary for PoolKey;

    function _hook() internal view returns (EssentialsHook) {
        return EssentialsHook(vm.envAddress("HOOK"));
    }

    function _key() internal view returns (PoolKey memory) {
        address t0 = vm.envAddress("TOKEN0");
        address t1 = vm.envAddress("TOKEN1");
        require(t0 < t1, "Interact: TOKEN0 must be < TOKEN1 (swap them)");
        uint24 fee = uint24(vm.envOr("FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(vm.envAddress("HOOK"))
        });
    }

    /// @notice Read-only: print the current batch state for the
    /// configured pool. Safe to run without --broadcast or a private key.
    function status() external view {
        EssentialsHook hook = _hook();
        PoolKey memory key = _key();

        EssentialsHook.BatchState memory b = hook.getBatch(key);
        uint256 queueLen = hook.getQueueLength(key);
        bool ready = hook.isBatchReady(key);

        console2.log("=== Essentials batch status ===");
        console2.log("hook:            ", address(hook));
        console2.log("current block:   ", block.number);
        console2.log("batch startBlock:", b.startBlock);
        console2.log("windowBlocks:    ", b.windowBlocks);
        console2.log("totalIn0:        ", b.totalIn0);
        console2.log("totalIn1:        ", b.totalIn1);
        console2.log("orders queued:   ", queueLen);
        console2.log("ready to settle: ", ready);

        if (b.startBlock != 0) {
            uint256 settleBlock = b.startBlock + b.windowBlocks + 1;
            if (block.number < settleBlock) {
                console2.log("blocks until settleable:", settleBlock - block.number);
            }
        }

        for (uint256 i = 0; i < queueLen; i++) {
            EssentialsHook.QueuedOrder memory o = hook.getQueuedOrder(key, i);
            console2.log("  order", i, o.zeroForOne ? "sell token0" : "sell token1");
            console2.log("    trader:", o.trader);
            console2.log("    amountIn:", o.amountIn);
        }
    }

    /// @notice Queue a swap as the broadcasting account. Requires that
    /// account to have already approved a PoolSwapTest router for the
    /// input token (deploys its own throwaway router each call, so
    /// approve `swapRouterAddress()` first -- run this script once to
    /// see the address it will use, or call `swapRouterAddress()`
    /// directly).
    function queueSwap(bool zeroForOne, uint256 amountIn) external {
        EssentialsHook hook = _hook();
        PoolKey memory key = _key();
        address caller = _broadcaster();

        vm.startBroadcast();
        PoolSwapTest swapRouter = new PoolSwapTest(hook.manager());
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(caller)
        );
        vm.stopBroadcast();

        console2.log(
            "queued: %s %s wei of the input token, at block %s",
            zeroForOne ? "sell token0" : "sell token1",
            amountIn,
            block.number
        );
        console2.log("trader credited:", caller);
        console2.log("queue length now:", hook.getQueueLength(key));

        console2.log("");
        console2.log("NOTE: this call deploys a fresh PoolSwapTest router each");
        console2.log("time. The broadcasting account must approve THAT router");
        console2.log("(printed above as the deployer of the tx) for the input");
        console2.log("token before this call, or the swap reverts. For repeat");
        console2.log("use, prefer a fixed, pre-approved router -- see");
        console2.log("script/demo/DemoPart1_SetupAndQueue.s.sol for that pattern.");
    }

    /// @notice Settle the batch. Reverts with EmptyBatch/BatchNotReady
    /// (wrapped) if not actually ready yet -- call `status()` first.
    function settle() external {
        EssentialsHook hook = _hook();
        PoolKey memory key = _key();

        vm.startBroadcast();
        hook.settleBatch(key);
        vm.stopBroadcast();

        console2.log("settled at block", block.number);
        console2.log("queue length now:", hook.getQueueLength(key));
    }

    /// @notice Add liquidity as the broadcasting account. Deploys its own
    /// throwaway PoolModifyLiquidityTest router each call -- same
    /// approval note as queueSwap applies.
    function addLiquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        EssentialsHook hook = _hook();
        PoolKey memory key = _key();

        vm.startBroadcast();
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(hook.manager());
        router.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: 0
            }),
            ""
        );
        vm.stopBroadcast();

        console2.log("liquidity added via router:", address(router));
        console2.log("tickLower/tickUpper/liquidityDelta:");
        console2.logInt(tickLower);
        console2.logInt(tickUpper);
        console2.logInt(liquidityDelta);
        console2.log("");
        console2.log("NOTE: liquidityDelta is a Uniswap L (sqrt-price-space)");
        console2.log("unit, NOT a token amount -- see EssentialsHook.sol's audit");
        console2.log("notes on this exact footgun. Use LiquidityAmounts off-chain");
        console2.log("(or in a wrapper script) to convert a desired token depth.");
    }

    /// @notice Remove liquidity from a position previously opened via
    /// addLiquidity with the SAME router address (position ownership in
    /// v4 is keyed by the calling router's address + tick range + salt,
    /// not by the underlying EOA -- see README's JIT-lock integration
    /// note). Pass the exact same router address addLiquidity printed.
    function removeLiquidity(address router, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        EssentialsHook hook = _hook();
        PoolKey memory key = _key();

        vm.startBroadcast();
        PoolModifyLiquidityTest(router).modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -liquidityDelta,
                salt: 0
            }),
            ""
        );
        vm.stopBroadcast();

        console2.log("liquidity removed via router:", router);
    }

    function _broadcaster() internal view returns (address) {
        (, address broadcaster,) = vm.readCallers();
        return broadcaster;
    }
}
