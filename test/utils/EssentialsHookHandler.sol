// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {EssentialsHook} from "../../src/EssentialsHook.sol";

/// @notice Bounded, revert-tolerant entry points for invariant fuzzing.
/// Every function catches its own reverts (JIT cooldown still active,
/// batch not ready yet, etc.) so a long random call sequence keeps
/// running instead of dying on the first expected revert — the invariant
/// runner only cares about the *global* properties asserted in
/// EssentialsHookInvariant.t.sol holding after every call, not about
/// individual calls always succeeding.
contract EssentialsHookHandler is Test {
    EssentialsHook public hook;
    PoolKey public key;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    Currency public currency0;
    Currency public currency1;

    address[] public traders;

    uint256 public ghost_settlementCount;
    uint256 public ghost_queueCount;

    constructor(
        EssentialsHook _hook,
        PoolKey memory _key,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _modifyLiquidityRouter,
        Currency _currency0,
        Currency _currency1,
        address[] memory _traders
    ) {
        hook = _hook;
        key = _key;
        swapRouter = _swapRouter;
        modifyLiquidityRouter = _modifyLiquidityRouter;
        currency0 = _currency0;
        currency1 = _currency1;
        traders = _traders;
    }

    function queueSwap(uint256 amountSeed, bool zeroForOne, uint8 traderSeed) external {
        uint256 amountIn = 0.01 ether + (amountSeed % 20 ether);
        address trader = traders[traderSeed % traders.length];

        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader)
        ) {
            ghost_queueCount++;
        } catch {
            // pool price limit hit, or some other benign revert -- fine,
            // the invariant runner just moves to the next call.
        }
    }

    function settleBatch() external {
        try hook.settleBatch(key) {
            ghost_settlementCount++;
        } catch {
            // EmptyBatch / BatchNotReady -- expected under many call
            // orderings, not a property violation.
        }
    }

    function rollBlocks(uint8 n) external {
        vm.roll(block.number + 1 + (n % 25));
    }

    function addLiquidity(uint8 saltSeed) external {
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e17,
                salt: bytes32(uint256(saltSeed))
            }),
            bytes("")
        ) {} catch {}
    }

    function removeLiquidity(uint8 saltSeed) external {
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1e17,
                salt: bytes32(uint256(saltSeed))
            }),
            bytes("")
        ) {} catch {
            // JIT cooldown still active, or no such position exists yet
            // -- both expected, not a failure.
        }
    }

    function tradersCount() external view returns (uint256) {
        return traders.length;
    }
}
