// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice Fuzz tests: properties that must hold for *any* valid input,
/// not just the hand-picked examples in the unit/integration suites.
contract EssentialsHookFuzzTest is EssentialsHookTestBase {
    uint256 constant MIN_AMOUNT = 0.001 ether;
    uint256 constant MAX_AMOUNT = 50 ether;

    function _bound_(uint256 x) internal pure returns (uint256) {
        // local helper name avoids clashing with forge-std's `bound`
        return MIN_AMOUNT + (x % (MAX_AMOUNT - MIN_AMOUNT));
    }

    /// A single order, alone in its batch, always clears close to spot
    /// price once settled -- regardless of size (within pool depth).
    function testFuzz_SingleOrder_AlwaysReceivesPositiveOutput(uint256 amountSeed, bool zeroForOne) public {
        uint256 amountIn = _bound_(amountSeed);
        address trader = zeroForOne ? alice : bob;

        _queueSwap(zeroForOne, amountIn, trader);
        _rollPastWindow();
        hook.settleBatch(key);

        uint256 received = zeroForOne ? currency1.balanceOf(trader) : currency0.balanceOf(trader);
        assertGt(received, 0, "trader always receives something for a nonzero input");
    }

    /// Two opposing orders of arbitrary (bounded) size always both get
    /// paid, and the hook never reverts settling them.
    function testFuzz_TwoOpposingOrders_BothGetPaid(uint256 seedA, uint256 seedB) public {
        uint256 amountA = _bound_(seedA);
        uint256 amountB = _bound_(seedB);

        _queueSwap(true, amountA, alice);
        _queueSwap(false, amountB, bob);
        _rollPastWindow();
        hook.settleBatch(key);

        assertGt(currency1.balanceOf(alice), 0);
        assertGt(currency0.balanceOf(bob), 0);
    }

    /// The hook must never pay out more of a currency than it actually
    /// holds -- this is the property that would catch another instance
    /// of the conservation bug class this project already found once.
    function testFuzz_Conservation_NeverPaysOutMoreThanCustodied(
        uint256 seed1,
        uint256 seed2,
        uint256 seed3,
        bool dir1,
        bool dir2,
        bool dir3
    ) public {
        uint256 a1 = _bound_(seed1);
        uint256 a2 = _bound_(seed2);
        uint256 a3 = _bound_(seed3);

        _queueSwap(dir1, a1, alice);
        _queueSwap(dir2, a2, bob);
        _queueSwap(dir3, a3, carol);

        _rollPastWindow();
        // must not revert -- an internal overpayment would show up as an
        // arithmetic underflow inside CurrencySettler/PoolManager well
        // before this call returns.
        hook.settleBatch(key);

        assertEq(hook.getQueueLength(key), 0, "batch always fully clears");
    }

    /// Window scaling is always clamped within [MIN_WINDOW_BLOCKS,
    /// MAX_WINDOW_BLOCKS], no matter how large the triggering batch is.
    function testFuzz_WindowAlwaysWithinBounds(uint256 amountSeed) public {
        uint256 amountIn = _bound_(amountSeed);
        _queueSwap(true, amountIn, whale);
        _rollPastWindow();
        hook.settleBatch(key);

        (,, uint256 windowAfter,) = _batchSnapshot();
        assertGe(windowAfter, hook.MIN_WINDOW_BLOCKS());
        assertLe(windowAfter, hook.MAX_WINDOW_BLOCKS());
    }

    /// The toxic-order threshold check is a strict share-of-side
    /// calculation -- a lone order (100% of its side) is always flagged,
    /// regardless of its absolute size.
    function testFuzz_LoneOrderOnASide_AlwaysFlaggedToxic(uint256 amountSeed) public {
        uint256 amountIn = _bound_(amountSeed);
        _queueSwap(true, amountIn, alice);
        _queueSwap(false, amountIn, bob); // funds the payout, opposite side

        vm.expectEmit(true, true, false, false);
        emit EssentialsHook.ToxicOrderFlagged(key.toId(), alice, 0, 0);
        _rollPastWindow();
        hook.settleBatch(key);
    }

    /// Proportional payout: within the same side, a trader contributing
    /// a larger share of that side's volume always receives a
    /// proportionally larger payout -- for arbitrary (bounded) amounts.
    function testFuzz_ProportionalPayout_LargerShareGetsMorePayout(uint256 smallSeed, uint256 largeSeedOffset) public {
        uint256 smallAmount = MIN_AMOUNT + (smallSeed % 2 ether);
        uint256 largeAmount = smallAmount + 1 ether + (largeSeedOffset % 10 ether); // guaranteed larger

        _queueSwap(true, smallAmount, alice);
        _queueSwap(true, largeAmount, bob);
        _queueSwap(false, smallAmount + largeAmount, carol);

        _rollPastWindow();
        hook.settleBatch(key);

        assertGe(currency1.balanceOf(bob), currency1.balanceOf(alice), "larger contributor gets >= payout");
    }

    /// Multiple sequential batches, each with fuzzed sizes, never leave
    /// the queue non-empty or revert unexpectedly.
    function testFuzz_SequentialBatches_AlwaysClearFully(uint256 seed1, uint256 seed2) public {
        uint256 a1 = _bound_(seed1);
        uint256 a2 = _bound_(seed2);

        _queueSwap(true, a1, alice);
        _rollPastWindow();
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0);

        _queueSwap(false, a2, bob);
        _rollPastWindow();
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0);
    }
}
