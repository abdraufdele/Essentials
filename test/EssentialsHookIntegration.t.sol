// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice Integration-level coverage: scenarios that only show up once
/// multiple orders, multiple batches, or multiple pools interact with the
/// same hook deployment.
contract EssentialsHookIntegrationTest is EssentialsHookTestBase {
    // Regression test for a real bug caught while building this suite:
    // a batch whose window expired without anyone calling settleBatch()
    // used to be silently `delete`d by the next incoming swap, orphaning
    // the input tokens already taken from earlier traders. Fixed by
    // force-settling the stale batch first. See EssentialsHook.sol
    // `_beforeSwap` for the fix and full explanation.

    function test_StaleBatch_ForceSettledInsteadOfDiscarded() public {
        // alice and bob queue into a batch that then goes unsettled...
        _queueSwap(true, 1 ether, alice);
        _queueSwap(false, 1 ether, bob);
        _rollPastWindow(); // window elapses, nobody calls settleBatch()

        assertEq(currency1.balanceOf(alice), 0, "alice not paid yet");
        assertEq(currency0.balanceOf(bob), 0, "bob not paid yet");

        // ...then carol's swap arrives. Before this fix, this call would
        // have wiped alice/bob's queued orders via `delete orderQueue[..]`
        // with no payout. Now it force-settles their batch first.
        _queueSwap(true, 0.5 ether, carol);

        assertGt(currency1.balanceOf(alice), 0, "alice's stale order was paid out, not lost");
        assertGt(currency0.balanceOf(bob), 0, "bob's stale order was paid out, not lost");

        // carol's own order should now be queued in the *new* batch
        assertEq(hook.getQueueLength(key), 1, "only carol's fresh order remains queued");
        assertEq(hook.getQueuedOrder(key, 0).trader, carol);
    }

    function test_StaleBatch_NewBatchStartsAtCurrentBlock() public {
        _queueSwap(true, 1 ether, alice);
        _rollPastWindow();
        uint256 blockAtSecondOrder = block.number;
        _queueSwap(true, 1 ether, bob);

        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertEq(b.startBlock, blockAtSecondOrder, "new batch opened at the block that triggered force-settlement");
        assertEq(b.totalIn0, 1 ether, "only bob's order counted in the new batch");
    }

    function test_StaleBatch_CarriesForwardVolatilityScaledWindow() public {
        // a big one-sided batch forces a wide next window via force-settlement
        _queueSwap(true, 50 ether, whale);
        _rollPastWindow();
        _queueSwap(true, 1 ether, alice); // triggers force-settlement of whale's batch

        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertGt(b.windowBlocks, hook.MIN_WINDOW_BLOCKS(), "volatility-scaled window carried into the new batch");
    }

    // Multi-order batches: conservation and correctness with >2 orders

    function test_MultiOrder_FourOrdersMixedDirectionsAllGetPaid() public {
        _queueSwap(true, 2 ether, alice);
        _queueSwap(true, 1 ether, bob);
        _queueSwap(false, 1.5 ether, carol);
        _queueSwap(false, 0.8 ether, dave);

        _rollPastWindow();
        hook.settleBatch(key);

        assertGt(currency1.balanceOf(alice), 0, "alice paid");
        assertGt(currency1.balanceOf(bob), 0, "bob paid");
        assertGt(currency0.balanceOf(carol), 0, "carol paid");
        assertGt(currency0.balanceOf(dave), 0, "dave paid");
    }

    function test_MultiOrder_PayoutProportionalToShareOfSide() public {
        // alice contributes 2x what bob does on the same (zeroForOne) side
        _queueSwap(true, 2 ether, alice);
        _queueSwap(true, 1 ether, bob);
        _queueSwap(false, 3 ether, carol); // funds both payouts

        _rollPastWindow();
        hook.settleBatch(key);

        // alice's payout should be ~2x bob's (same side, same clearing price)
        assertApproxEqRel(currency1.balanceOf(alice), currency1.balanceOf(bob) * 2, 0.01e18);
    }

    function test_MultiOrder_PerfectlyNettedBatchNeedsNoResidualSwap() public {
        // exactly opposing, equal-value orders at the pool's 1:1 price
        _queueSwap(true, 3 ether, alice);
        _queueSwap(false, 3 ether, bob);

        _rollPastWindow();
        hook.settleBatch(key);

        // both should receive ~exactly what the other side put in (1:1 price)
        assertApproxEqRel(currency1.balanceOf(alice), 3 ether, 0.01e18);
        assertApproxEqRel(currency0.balanceOf(bob), 3 ether, 0.01e18);
    }

    function test_MultiOrder_SingleOrderBatchStillSettles() public {
        // a batch with only one order (no counterparty) still clears via
        // the residual swap against the pool.
        _queueSwap(true, 1 ether, alice);
        _rollPastWindow();
        hook.settleBatch(key);
        assertApproxEqRel(currency1.balanceOf(alice), 1 ether, 0.02e18);
    }

    // Sequential batches on the same pool

    function test_SequentialBatches_SecondBatchIndependentOfFirst() public {
        _queueSwap(true, 1 ether, alice);
        _rollPastWindow();
        hook.settleBatch(key);
        uint256 aliceBalanceAfterFirst = currency1.balanceOf(alice);

        _queueSwap(true, 1 ether, bob);
        _rollPastWindow();
        hook.settleBatch(key);

        // alice's balance from batch 1 is untouched by batch 2
        assertEq(currency1.balanceOf(alice), aliceBalanceAfterFirst);
        assertGt(currency1.balanceOf(bob), 0, "bob paid from the second, independent batch");
    }

    function test_SequentialBatches_ThreeInARow() public {
        for (uint256 i = 0; i < 3; i++) {
            _queueSwap(true, 1 ether, alice);
            _queueSwap(false, 1 ether, bob);
            _rollPastWindow();
            hook.settleBatch(key);
        }
        assertEq(hook.getQueueLength(key), 0, "queue empty after three settled batches");
        assertGt(currency1.balanceOf(alice), 0);
        assertGt(currency0.balanceOf(bob), 0);
    }

    // Multi-pool isolation: two pools sharing the same hook deployment
    // must not leak state into each other.

    function test_MultiPool_BatchStateIsolatedPerPool() public {
        (PoolKey memory key2,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(key2, 100 ether, 100 ether);

        _queueSwap(true, 1 ether, alice); // pool 1
        _queueSwapOn(key2, true, 5 ether, bob); // pool 2

        assertEq(hook.getQueueLength(key), 1, "pool 1 has only alice's order");
        assertEq(hook.getQueueLength(key2), 1, "pool 2 has only bob's order");

        EssentialsHook.BatchState memory b1 = hook.getBatch(key);
        EssentialsHook.BatchState memory b2 = hook.getBatch(key2);
        assertEq(b1.totalIn0, 1 ether);
        assertEq(b2.totalIn0, 5 ether);
    }

    function test_MultiPool_SettlingOneDoesNotAffectTheOther() public {
        (PoolKey memory key2,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(key2, 100 ether, 100 ether);

        _queueSwap(true, 1 ether, alice);
        _queueSwapOn(key2, true, 5 ether, bob);

        _rollPastWindow(); // rolls past pool 1's window
        hook.settleBatch(key);

        assertEq(hook.getQueueLength(key), 0, "pool 1 settled");
        assertEq(hook.getQueueLength(key2), 1, "pool 2 untouched by pool 1's settlement");
    }

    // JIT lock interacting with a real batch settlement (LPs earning
    // recapture donations while still being subject to the lock)

    function test_Jit_LockStillEnforcedAfterABatchSettles() public {
        // a batch settles (generating LP recapture via donate()) first...
        _queueSwap(true, 19 ether, whale);
        _queueSwap(true, 1 ether, alice);
        _queueSwap(false, 20 ether, bob);
        _rollPastWindow();
        hook.settleBatch(key);

        // ...then an LP adds liquidity right at settlement time, using a
        // fresh salt so this position is independent of whatever setUp()
        // already opened at the default salt. JIT lock is independent of
        // batch settlement -- still enforced.
        IPoolManager.ModifyLiquidityParams memory freshAdd = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: LIQUIDITY_PARAMS.liquidityDelta,
            salt: bytes32(uint256(42))
        });
        modifyLiquidityRouter.modifyLiquidity(key, freshAdd, ZERO_BYTES);

        IPoolManager.ModifyLiquidityParams memory freshRemove = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: -LIQUIDITY_PARAMS.liquidityDelta,
            salt: bytes32(uint256(42))
        });
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, freshRemove, ZERO_BYTES);
    }

    // Conservation: the hook must never pay out more than it took in
    // (across a realistic, mixed-size, multi-trader batch)

    function test_Conservation_HookNeverOverpaysAcrossMixedBatch() public {
        uint256 hookToken0Before = currency0.balanceOf(address(hook));
        uint256 hookToken1Before = currency1.balanceOf(address(hook));

        _queueSwap(true, 4 ether, alice);
        _queueSwap(true, 1 ether, whale); // will *not* be toxic here (only 20% of side)
        _queueSwap(false, 3 ether, bob);
        _queueSwap(false, 0.5 ether, carol);

        _rollPastWindow();
        hook.settleBatch(key);

        // the hook contract itself should not have accumulated a growing
        // token balance across the settlement -- everything taken in is
        // either paid out, donated to LPs, or left as negligible dust.
        uint256 hookToken0After = currency0.balanceOf(address(hook));
        uint256 hookToken1After = currency1.balanceOf(address(hook));

        assertLt(hookToken0After, 0.001 ether + hookToken0Before, "no meaningful token0 stuck in hook");
        assertLt(hookToken1After, 0.001 ether + hookToken1Before, "no meaningful token1 stuck in hook");
    }
}
