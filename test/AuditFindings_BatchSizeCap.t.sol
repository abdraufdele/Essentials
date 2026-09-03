// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice AUDIT FINDING [HIGH]: unbounded batch size enabled a
/// permanent-lockup DoS -- settlement gas scaled linearly with queue
/// size (~28k gas/order measured), and an attacker spamming ~1,000+
/// small orders into one batch could push settlement gas above a single
/// block's gas limit, making that batch (and every honest participant's
/// funds already taken into custody) permanently unsettleable.
///
/// FIX: MAX_BATCH_SIZE caps the queue; further swaps in a full batch
/// revert with BatchFull() and must be resubmitted for the next batch.
contract AuditFindings_BatchSizeCapTest is EssentialsHookTestBase {
    function test_GasCostScalesWithQueueSize_50Orders() public {
        _spamOrders(50);
        _rollPastWindow();
        uint256 gasBefore = gasleft();
        hook.settleBatch(key);
        emit log_named_uint("gas used settling a 50-order batch", gasBefore - gasleft());
    }

    function test_GasCostScalesWithQueueSize_AtCap() public {
        _spamOrders(hook.MAX_BATCH_SIZE());
        _rollPastWindow();
        uint256 gasBefore = gasleft();
        hook.settleBatch(key);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("gas used settling a full (MAX_BATCH_SIZE) batch", gasUsed);
        // even at the cap, settlement must comfortably fit in a single
        // Ethereum block (~30M gas) with real margin to spare.
        assertLt(gasUsed, 8_000_000, "settlement at max batch size must fit comfortably in a block");
    }

    /// FIX VERIFICATION: once a batch hits MAX_BATCH_SIZE, further swaps
    /// in that window revert with BatchFull() instead of being accepted
    /// -- this is what actually prevents the unbounded-growth DoS, not
    /// just "it happens to still fit in a block at some size."
    function test_Fix_FurtherOrdersRevertOnceBatchIsFull() public {
        _spamOrders(hook.MAX_BATCH_SIZE());
        assertEq(hook.getQueueLength(key), hook.MAX_BATCH_SIZE());

        vm.expectRevert(); // wrapped by Hooks; inner revert is BatchFull()
        _queueSwap(true, 1 ether, alice);
    }

    function test_Fix_NextBatchAcceptsOrdersAfterPreviousFullOneSettles() public {
        _spamOrders(hook.MAX_BATCH_SIZE());
        _rollPastWindow();
        hook.settleBatch(key);

        // the batch that was full is now settled and cleared; a fresh
        // batch accepts new orders normally.
        _queueSwap(true, 1 ether, alice);
        assertEq(hook.getQueueLength(key), 1);
    }

    function _spamOrders(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address trader = address(uint160(uint256(keccak256(abi.encode("spam", i)))));
            _queueSwap(i % 2 == 0, 0.001 ether, trader);
        }
    }
}
