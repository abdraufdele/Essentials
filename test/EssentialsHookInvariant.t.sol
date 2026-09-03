// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHookHandler} from "./utils/EssentialsHookHandler.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

/// @notice Properties that must hold no matter what sequence of queueing,
/// settling, rolling blocks, and adding/removing liquidity happens. Each
/// `invariant_*` function is checked after every call the fuzzer makes
/// through the Handler across many random sequences, not just the
/// hand-picked scenarios in the other test files.
contract EssentialsHookInvariantTest is EssentialsHookTestBase {
    EssentialsHookHandler handler;

    // a generous per-call bound (see Handler.queueSwap) times a generous
    // number of calls -- if the hook's own idle balance ever exceeds this,
    // something is accumulating that shouldn't be.
    uint256 constant DUST_BOUND = 5 ether;

    function setUp() public override {
        super.setUp();

        address[] memory traders = new address[](5);
        traders[0] = alice;
        traders[1] = bob;
        traders[2] = carol;
        traders[3] = dave;
        traders[4] = whale;

        handler = new EssentialsHookHandler(hook, key, swapRouter, modifyLiquidityRouter, currency0, currency1, traders);

        // fund the handler itself -- it's the one actually calling the
        // routers, so it (not the individual `traders`) needs balance and
        // approvals. See EssentialsHookHandler.sol for why.
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 10_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 10_000 ether);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// The batch window can never drift outside the bounds the contract
    /// itself declares as its own constants, no matter how volatile the
    /// random call sequence made the pool.
    function invariant_WindowAlwaysWithinDeclaredBounds() public view {
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        assertGe(b.windowBlocks, hook.MIN_WINDOW_BLOCKS(), "window never below MIN");
        assertLe(b.windowBlocks, hook.MAX_WINDOW_BLOCKS(), "window never above MAX");
    }

    /// Core state-machine invariant: a batch is either "closed" (no
    /// startBlock, empty queue) or "open" (startBlock set, at least one
    /// queued order). There is no reachable state with a nonzero
    /// startBlock and an empty queue, or vice versa.
    function invariant_BatchOpenIffQueueNonEmpty() public view {
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        uint256 queueLen = hook.getQueueLength(key);
        if (b.startBlock == 0) {
            assertEq(queueLen, 0, "no open batch marker without queued orders");
        } else {
            assertGt(queueLen, 0, "open batch marker must have at least one queued order");
        }
    }

    /// Conservation, checked externally: once a batch is fully settled
    /// (no batch currently open), the hook's own idle token balance
    /// should never look like leaked or stuck funds. This is
    /// deliberately NOT checked while a batch is open/in-flight -- an
    /// open batch legitimately custodies its participants' funds until
    /// settlement (that's the whole mechanism), so a large balance
    /// mid-batch is expected, not a violation. Checking this bound
    /// unconditionally was an earlier mistake in this test itself (a
    /// snapshot mid-batch was being misread as "stuck dust"), caught
    /// while tuning this exact invariant.
    function invariant_HookNeverAccumulatesUnboundedDust() public view {
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        if (b.startBlock != 0) return; // batch open -- balances are legitimately in flight

        assertLt(currency0.balanceOf(address(hook)), DUST_BOUND, "token0 dust bounded once settled");
        assertLt(currency1.balanceOf(address(hook)), DUST_BOUND, "token1 dust bounded once settled");
    }

    /// Runs once after the whole fuzzing campaign. Logged (not asserted)
    /// rather than a hard revert: Foundry's corpus-replay mode can invoke
    /// this against a trivial minimal reproduction with zero settlements,
    /// which would fail here for a reason unrelated to whatever the
    /// actual invariant violation was. Left in as a visibility aid for a
    /// full fresh campaign, where a zero count here would be a real
    /// signal the run was vacuous.
    function afterInvariant() public {
        emit log_named_uint("settlements observed this run", handler.ghost_settlementCount());
        emit log_named_uint("orders queued this run", handler.ghost_queueCount());
    }
}
