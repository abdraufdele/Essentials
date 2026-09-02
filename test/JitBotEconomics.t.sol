// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";
import {CurrencySettler} from "../src/libraries/CurrencySettler.sol";

/// @dev PoolModifyLiquidityTest (the standard test router) discards
/// PoolManager.modifyLiquidity's second return value (`feesAccrued`),
/// only exposing the combined principal+fees delta. This minimal router
/// captures `feesAccrued` distinctly, which is what lets the tests below
/// isolate "how much fee did this specific position earn" cleanly from
/// principal/impermanent-loss effects, instead of trying to back that
/// number out of noisy net-balance-change arithmetic.
contract FeeCapturingRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    BalanceDelta public lastFeesAccrued;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        bytes memory result = manager.unlock(abi.encode(CallbackData(msg.sender, key, params)));
        (delta, feesAccrued) = abi.decode(result, (BalanceDelta, BalanceDelta));
        lastFeesAccrued = feesAccrued;
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (BalanceDelta delta, BalanceDelta feesAccrued) = manager.modifyLiquidity(data.key, data.params, "");

        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();
        if (d0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-d0), false);
        if (d1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-d1), false);
        if (d0 > 0) data.key.currency0.take(manager, data.sender, uint256(d0), false);
        if (d1 > 0) data.key.currency1.take(manager, data.sender, uint256(d1), false);

        return abi.encode(delta, feesAccrued);
    }
}

/// @notice Quantifies the JIT (just-in-time liquidity) problem in bps,
/// the same way EssentialsHook.t.sol quantifies the sandwich problem.
///
/// A note on framing, arrived at after actually trying the naive version
/// first: an early draft of this file tried to show a JIT bot's own net
/// P&L is positive on a vanilla pool. Empirically (via a parameter
/// sweep), that number is marginal-to-negative at realistic single-swap
/// scales once real concentrated-liquidity price exposure is accounted
/// for -- forcing a clean positive number would have meant cherry-picking
/// parameters, not demonstrating something real.
///
/// The metric the actual JIT-liquidity research literature uses instead
/// -- and the one that's real regardless of the sniping bot's own P&L --
/// is FEE DILUTION: a JIT bot that adds a large, tightly-concentrated
/// position right before a known large trade and removes it right after
/// captures a share of that trade's fee that would otherwise have gone
/// to genuine, standing LPs. That dilution is real and positive by
/// construction any time the bot can execute the strategy at all; this
/// file measures it directly, and shows the JIT lock reduces it to zero
/// by making the strategy impossible to execute (not just less
/// profitable).
contract JitBotEconomicsTest is EssentialsHookTestBase {
    using StateLibrary for IPoolManager;

    // Desired REAL token depth for each position, converted to the
    // correct Uniswap "L" liquidity unit via LiquidityAmounts below --
    // NOT passed directly as liquidityDelta. Confirmed while calibrating
    // this file that liquidityDelta is a sqrt-price-space unit, not a
    // token amount: passing raw ether-scale numbers directly as
    // liquidityDelta silently created positions with far less real token
    // depth than intended, which is why earlier attempts here kept
    // producing unusable near-zero or fully-drained-pool results.
    uint256 constant BASELINE_TOKEN_DEPTH = 20 ether;
    uint256 constant JIT_TOKEN_DEPTH = 60 ether;
    uint256 constant TRADE_SIZE = 5 ether;
    int24 constant RANGE = 600;
    bytes32 constant BASELINE_SALT = bytes32(uint256(100));
    bytes32 constant JIT_SALT = bytes32(uint256(200));

    FeeCapturingRouter feeRouter;

    function setUp() public override {
        super.setUp();
        feeRouter = new FeeCapturingRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(feeRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(feeRouter), type(uint256).max);
    }

    function _liquidityFor(PoolKey memory k, uint256 tokenDepth) internal view returns (int256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(-RANGE),
            TickMath.getSqrtPriceAtTick(RANGE),
            tokenDepth,
            tokenDepth
        );
        return int256(uint256(l));
    }

    /// @dev Adds a standing baseline LP position via the fee-capturing
    /// router, runs one large swap, and returns the fee-only BalanceDelta
    /// earned by the baseline position when it's removed -- isolated
    /// directly from PoolManager.modifyLiquidity's second return value,
    /// not backed out of noisy net-balance-change arithmetic (an earlier
    /// version of this file tried that and principal/IL effects
    /// dominated the signal).
    function _baselineLpFeesAccrued(PoolKey memory k, bool jitBotParticipates)
        internal
        returns (int256 feeToken0, int256 feeToken1)
    {
        int256 baselineL = _liquidityFor(k, BASELINE_TOKEN_DEPTH);
        IPoolManager.ModifyLiquidityParams memory baselineAdd = IPoolManager.ModifyLiquidityParams({
            tickLower: -RANGE,
            tickUpper: RANGE,
            liquidityDelta: baselineL,
            salt: BASELINE_SALT
        });
        IPoolManager.ModifyLiquidityParams memory baselineRemove = IPoolManager.ModifyLiquidityParams({
            tickLower: -RANGE,
            tickUpper: RANGE,
            liquidityDelta: -baselineL,
            salt: BASELINE_SALT
        });

        feeRouter.modifyLiquidity(k, baselineAdd);

        if (jitBotParticipates) {
            int256 jitL = _liquidityFor(k, JIT_TOKEN_DEPTH);
            IPoolManager.ModifyLiquidityParams memory jitAdd = IPoolManager.ModifyLiquidityParams({
                tickLower: -RANGE,
                tickUpper: RANGE,
                liquidityDelta: jitL,
                salt: JIT_SALT
            });
            modifyLiquidityRouter.modifyLiquidity(k, jitAdd, ZERO_BYTES);
        }

        swap(k, true, -int256(TRADE_SIZE), ZERO_BYTES);

        if (jitBotParticipates) {
            int256 jitL = _liquidityFor(k, JIT_TOKEN_DEPTH);
            IPoolManager.ModifyLiquidityParams memory jitRemove = IPoolManager.ModifyLiquidityParams({
                tickLower: -RANGE,
                tickUpper: RANGE,
                liquidityDelta: -jitL,
                salt: JIT_SALT
            });
            modifyLiquidityRouter.modifyLiquidity(k, jitRemove, ZERO_BYTES);
        }

        (, BalanceDelta fees) = feeRouter.modifyLiquidity(k, baselineRemove);
        feeToken0 = fees.amount0();
        feeToken1 = fees.amount1();
    }

    function test_JitBot_DilutesBaselineLpFees_OnVanillaPool() public {
        (PoolKey memory soloKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        (int256 fee0Alone, int256 fee1Alone) = _baselineLpFeesAccrued(soloKey, false);
        int256 feeAlone = fee0Alone + fee1Alone; // ~1:1 price at this pool state

        // same fee tier for a fair comparison; different tickSpacing only
        // to avoid re-initializing the identical pool key.
        (PoolKey memory dilutedKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, 200, SQRT_PRICE_1_1);
        (int256 fee0WithJit, int256 fee1WithJit) = _baselineLpFeesAccrued(dilutedKey, true);
        int256 feeWithJit = fee0WithJit + fee1WithJit;

        emit log_named_int("baseline LP fees earned, alone (wei, token0-equivalent)", feeAlone);
        emit log_named_int("baseline LP fees earned, JIT bot also participates (wei)", feeWithJit);
        emit log_named_int(
            "dilution (bps of what the baseline LP earned alone)",
            feeAlone == 0 ? int256(0) : ((feeAlone - feeWithJit) * 10_000) / feeAlone
        );

        // the standing LP earns strictly less of the trade's fee when a
        // JIT bot shows up and captures a share of it -- this is the
        // real, always-present harm the JIT-liquidity literature
        // describes, isolated cleanly from principal/IL noise.
        assertLt(feeWithJit, feeAlone, "JIT participation dilutes the standing LP's fee earnings");
        assertGt(feeAlone, 0, "sanity: the baseline LP should earn a real, positive fee when alone");
    }

    function test_JitBot_CannotDiluteFees_OnHookedPool() public {
        // same setup on the hook-protected pool: the bot ADDS liquidity
        // fine (that's never restricted), but cannot remove it
        // immediately after, so a rational bot never executes the
        // strategy in the first place -- fee dilution is prevented at
        // the source, not just penalized after the fact.
        IPoolManager.ModifyLiquidityParams memory jitAdd = IPoolManager.ModifyLiquidityParams({
            tickLower: -RANGE,
            tickUpper: RANGE,
            liquidityDelta: 1e18, // any nonzero, valid liquidity amount -- the point being tested is the revert, not the size
            salt: JIT_SALT
        });
        IPoolManager.ModifyLiquidityParams memory jitRemove = IPoolManager.ModifyLiquidityParams({
            tickLower: -RANGE,
            tickUpper: RANGE,
            liquidityDelta: -1e18,
            salt: JIT_SALT
        });

        modifyLiquidityRouter.modifyLiquidity(key, jitAdd, ZERO_BYTES);
        vm.expectRevert(); // JitCooldownActive, wrapped by Hooks
        modifyLiquidityRouter.modifyLiquidity(key, jitRemove, ZERO_BYTES);

        // the bot's capital is now locked for JIT_LOCK_BLOCKS, fully
        // exposed to ordinary price risk instead of being extracted
        // risk-free within the same block-scale window -- the strategy
        // this test's vanilla-pool counterpart measured is denied
        // entirely, not merely taxed.
    }
}
