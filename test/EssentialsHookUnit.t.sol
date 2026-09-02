// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice Unit-level coverage: every public constant, every error branch,
/// every view accessor, and the trader/hookData decoding logic, each
/// exercised in isolation from the rest of the settlement pipeline.
contract EssentialsHookUnitTest is EssentialsHookTestBase {
    // getHookPermissions()

    function test_Permissions_MatchDeployedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize, "afterInitialize");
        assertTrue(p.afterAddLiquidity, "afterAddLiquidity");
        assertTrue(p.beforeRemoveLiquidity, "beforeRemoveLiquidity");
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
    }

    function test_Permissions_EverythingElseIsFalse() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // public constants — these are part of the contract's public
    // interface and any accidental change to them is a silent
    // behavior change, so they're pinned explicitly.

    function test_Constants_WindowBounds() public view {
        assertEq(hook.MIN_WINDOW_BLOCKS(), 2);
        assertEq(hook.MAX_WINDOW_BLOCKS(), 20);
        assertLt(hook.MIN_WINDOW_BLOCKS(), hook.MAX_WINDOW_BLOCKS(), "min must be below max");
    }

    function test_Constants_JitLockBlocks() public view {
        assertEq(hook.JIT_LOCK_BLOCKS(), 3);
    }

    function test_Constants_ToxicThresholdAndSurcharge() public view {
        assertEq(hook.TOXIC_SHARE_OF_SIDE_BPS(), 5000);
        assertEq(hook.TOXIC_SURCHARGE_BPS(), 30);
        assertLt(hook.TOXIC_SURCHARGE_BPS(), 10_000, "surcharge must be less than 100%");
    }

    function test_Constants_LpRecaptureShare() public view {
        assertEq(hook.LP_RECAPTURE_SHARE_BPS(), 5000);
        assertLe(hook.LP_RECAPTURE_SHARE_BPS(), 10_000, "share can't exceed 100%");
    }

    // afterInitialize

    function test_AfterInitialize_SeedsMinWindow() public view {
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertEq(b.windowBlocks, hook.MIN_WINDOW_BLOCKS(), "window seeded to minimum on init");
        assertEq(b.startBlock, 0, "no batch open yet");
    }

    function test_AfterInitialize_SeedsObservedTick() public view {
        // pool was initialized at 1:1, so tick should be (near) zero
        int24 tick = hook.lastObservedTick(key.toId());
        assertEq(tick, 0, "SQRT_PRICE_1_1 corresponds to tick 0");
    }

    // beforeSwap — error branches

    function test_BeforeSwap_RevertsOnExactOutput() public {
        vm.expectRevert(); // wrapped by Hooks.wrap(); inner revert is ExactOutputNotSupported
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _poolSwapTestSettings(),
            abi.encode(alice)
        );
    }

    function test_BeforeSwap_RevertsOnZeroAmount() public {
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _poolSwapTestSettings(),
            abi.encode(alice)
        );
    }

    // beforeSwap — batch bookkeeping

    function test_BeforeSwap_OpensFreshBatchOnFirstOrder() public {
        assertEq(hook.getBatch(key).startBlock, 0);
        _queueSwap(true, 1 ether, alice);
        assertEq(hook.getBatch(key).startBlock, block.number, "batch opened at current block");
    }

    function test_BeforeSwap_AccumulatesTotalsPerSide() public {
        _queueSwap(true, 1 ether, alice);
        _queueSwap(true, 2 ether, bob);
        _queueSwap(false, 0.5 ether, carol);

        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertEq(b.totalIn0, 3 ether, "sum of zeroForOne orders");
        assertEq(b.totalIn1, 0.5 ether, "sum of oneForZero orders");
    }

    function test_BeforeSwap_PushesOrderWithCorrectFields() public {
        _queueSwap(true, 1.5 ether, alice);
        EssentialsHook.QueuedOrder memory o = hook.getQueuedOrder(key, 0);
        assertEq(o.trader, alice);
        assertTrue(o.zeroForOne);
        assertEq(o.amountIn, 1.5 ether);
        assertEq(o.minAmountOut, 0, "no minOut encoded in this call");
    }

    function test_BeforeSwap_EmitsOrderQueued() public {
        vm.expectEmit(true, true, false, true);
        emit EssentialsHook.OrderQueued(key.toId(), alice, true, 1 ether, block.number);
        _queueSwap(true, 1 ether, alice);
    }

    // hookData decoding (_decodeTrader): three call shapes

    function test_DecodeTrader_EmptyHookDataUsesSender() public {
        // swapRouter itself becomes "sender" as seen by the hook when no
        // trader is encoded — calling swap() with empty hookData directly
        // (not via the _queueSwap helper, which always encodes a trader).
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _poolSwapTestSettings(),
            bytes("")
        );
        EssentialsHook.QueuedOrder memory o = hook.getQueuedOrder(key, 0);
        assertEq(o.trader, address(swapRouter), "falls back to the router as sender");
    }

    function test_DecodeTrader_AddressOnlyHookData() public {
        _queueSwap(true, 1 ether, alice); // encodes abi.encode(alice) — 32 bytes
        assertEq(hook.getQueuedOrder(key, 0).trader, alice);
        assertEq(hook.getQueuedOrder(key, 0).minAmountOut, 0);
    }

    function test_DecodeTrader_AddressAndMinOutHookData() public {
        _queueSwapWithMinOut(true, 1 ether, alice, 0.95 ether); // 64 bytes
        EssentialsHook.QueuedOrder memory o = hook.getQueuedOrder(key, 0);
        assertEq(o.trader, alice);
        assertEq(o.minAmountOut, 0.95 ether);
    }

    function test_DecodeTrader_ZeroAddressFallsBackToSender() public {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _poolSwapTestSettings(),
            abi.encode(address(0))
        );
        // explicit address(0) in hookData should not leave funds
        // permanently unclaimable — falls back to the calling router.
        assertEq(hook.getQueuedOrder(key, 0).trader, address(swapRouter));
    }

    // isBatchReady()

    function test_IsBatchReady_FalseWhenQueueEmpty() public view {
        assertFalse(hook.isBatchReady(key));
    }

    function test_IsBatchReady_FalseBeforeWindowElapses() public {
        _queueSwap(true, 1 ether, alice);
        assertFalse(hook.isBatchReady(key), "window hasn't elapsed yet");
    }

    function test_IsBatchReady_TrueAfterWindowElapses() public {
        _queueSwap(true, 1 ether, alice);
        _rollPastWindow();
        assertTrue(hook.isBatchReady(key));
    }

    // settleBatch() — guard clauses

    function test_SettleBatch_RevertsEmptyBatch() public {
        vm.expectRevert(EssentialsHook.EmptyBatch.selector);
        hook.settleBatch(key);
    }

    function test_SettleBatch_RevertsBatchNotReady() public {
        _queueSwap(true, 1 ether, alice);
        vm.expectRevert(EssentialsHook.BatchNotReady.selector);
        hook.settleBatch(key);
    }

    function test_SettleBatch_SucceedsExactlyAtWindowBoundary() public {
        _queueSwap(true, 1 ether, alice);
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        // one block *past* start+window is required (strict >), confirm
        // the boundary block itself still reverts...
        vm.roll(b.startBlock + b.windowBlocks);
        vm.expectRevert(EssentialsHook.BatchNotReady.selector);
        hook.settleBatch(key);
        // ...and the very next block succeeds.
        vm.roll(b.startBlock + b.windowBlocks + 1);
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0);
    }

    function test_SettleBatch_IsPermissionless() public {
        _queueSwap(true, 1 ether, alice);
        _queueSwap(false, 1 ether, bob);
        _rollPastWindow();
        // settled by a totally unrelated address, not the trader or deployer
        vm.prank(makeAddr("randomKeeper"));
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0);
    }

    // view accessors

    function test_GetQueueLength_TracksPushedOrders() public {
        assertEq(hook.getQueueLength(key), 0);
        _queueSwap(true, 1 ether, alice);
        assertEq(hook.getQueueLength(key), 1);
        _queueSwap(false, 1 ether, bob);
        assertEq(hook.getQueueLength(key), 2);
    }

    function test_GetQueueLength_ResetsAfterSettlement() public {
        _queueSwap(true, 1 ether, alice);
        _rollPastWindow();
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0);
    }

    function test_GetBatch_ResetsFieldsAfterSettlement() public {
        _queueSwap(true, 1 ether, alice);
        _queueSwap(false, 1 ether, bob);
        _rollPastWindow();
        hook.settleBatch(key);

        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertEq(b.startBlock, 0, "startBlock reset");
        assertEq(b.totalIn0, 0, "totalIn0 reset");
        assertEq(b.totalIn1, 0, "totalIn1 reset");
        // windowBlocks is NOT reset to zero — it carries the freshly
        // volatility-scaled value for the next batch.
        assertGe(b.windowBlocks, hook.MIN_WINDOW_BLOCKS());
    }

    // JIT lock — position-key isolation

    function test_Jit_LiquidityAddedAtBlock_RecordsCurrentBlock() public {
        vm.roll(12345);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        bytes32 posKey = keccak256(
            abi.encode(
                key.toId(),
                address(modifyLiquidityRouter),
                LIQUIDITY_PARAMS.tickLower,
                LIQUIDITY_PARAMS.tickUpper,
                LIQUIDITY_PARAMS.salt
            )
        );
        assertEq(hook.liquidityAddedAtBlock(posKey), 12345);
    }

    function test_Jit_RevertsWithinCooldownWindow() public {
        // Note: `JitBlocked` is emitted on the same line immediately before
        // the revert, so it's only observable in a revert *trace* (useful
        // for off-chain tooling like Tenderly), never as an actual
        // transaction log — EVM discards all logs from a reverted call
        // frame. So this test asserts the revert itself, which is the
        // only externally-observable effect.
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        vm.roll(block.number + 1); // 1 block later, 2 remain until JIT_LOCK_BLOCKS (3)
        vm.expectRevert(); // wrapped by Hooks; inner revert is JitCooldownActive
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_Jit_DifferentPositionsTrackedIndependently() public {
        // position A added now
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        // roll forward so a *new* position (different tick range) opened
        // later is NOT constrained by position A's cooldown
        vm.roll(block.number + hook.JIT_LOCK_BLOCKS() + 1);
        IPoolManager.ModifyLiquidityParams memory otherRange = IPoolManager.ModifyLiquidityParams({
            tickLower: -180,
            tickUpper: 180,
            liquidityDelta: 1e18,
            salt: bytes32(uint256(1))
        });
        modifyLiquidityRouter.modifyLiquidity(key, otherRange, ZERO_BYTES);

        // position A is well past its own cooldown now too
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        // position B (just added) is still within ITS OWN cooldown
        IPoolManager.ModifyLiquidityParams memory removeOther = IPoolManager.ModifyLiquidityParams({
            tickLower: -180,
            tickUpper: 180,
            liquidityDelta: -1e18,
            salt: bytes32(uint256(1))
        });
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, removeOther, ZERO_BYTES);
    }
}
