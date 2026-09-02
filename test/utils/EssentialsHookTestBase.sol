// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {HookMiner} from "./HookMiner.sol";
import {EssentialsHook} from "../../src/EssentialsHook.sol";

/// @notice Shared setup + helpers for every EssentialsHook test file (unit,
/// integration, fuzz, invariant, JIT economics). Keeping this in one place
/// means every file exercises the *same* deployment/pool-init path, so a
/// passing test in one file is directly comparable to a passing test in
/// another.
abstract contract EssentialsHookTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    EssentialsHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = _deployHook();

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // seed extra depth so residual-swap price impact in tests is modest
        seedMoreLiquidity(key, 500 ether, 500 ether);
    }

    function _deployHook() internal returns (EssentialsHook) {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(EssentialsHook).creationCode, constructorArgs);
        EssentialsHook deployed = new EssentialsHook{salt: salt}(manager);
        require(address(deployed) == hookAddress, "hook address mismatch");
        return deployed;
    }

    // ─────────────────────────────────────────────────────────────
    // shared helpers
    // ─────────────────────────────────────────────────────────────

    function _queueSwap(bool zeroForOne, uint256 amountIn, address trader) internal {
        _queueSwapOn(key, zeroForOne, amountIn, trader);
    }

    function _queueSwapOn(PoolKey memory k, bool zeroForOne, uint256 amountIn, address trader) internal {
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            _poolSwapTestSettings(),
            abi.encode(trader)
        );
    }

    function _queueSwapWithMinOut(bool zeroForOne, uint256 amountIn, address trader, uint128 minOut) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            _poolSwapTestSettings(),
            abi.encode(trader, minOut)
        );
    }

    function _poolSwapTestSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _rollPastWindow() internal {
        _rollPastWindowOn(key);
    }

    function _rollPastWindowOn(PoolKey memory k) internal {
        EssentialsHook.BatchState memory b = hook.getBatch(k);
        vm.roll(block.number > b.startBlock + b.windowBlocks + 1 ? block.number : b.startBlock + b.windowBlocks + 1);
    }

    function _batchSnapshot()
        internal
        view
        returns (uint256 startBlock, uint256 totalIn0, uint256 windowBlocks, uint256 totalIn1)
    {
        EssentialsHook.BatchState memory b = hook.getBatch(key);
        return (b.startBlock, b.totalIn0, b.windowBlocks, b.totalIn1);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
