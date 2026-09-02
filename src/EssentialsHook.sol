// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * ESSENTIALS — Batch-Clearing MEV-Mitigating Hook
 *
 * A Uniswap v4 hook that replaces per-swap execution with short, on-chain
 * batch auctions. Every swap routed through a pool using this hook is
 * queued instead of executed immediately. When a batch window closes,
 * anyone can call `settleBatch`, which:
 *
 *   1. Nets opposing orders against each other directly (no pool contact
 *      needed for the matched portion — this is the part that makes
 *      sandwiching structurally impossible: there is no "before" and
 *      "after" position to sandwich, because there is no ordering within
 *      the batch that changes anyone's price).
 *   2. Executes exactly ONE swap against the pool for the residual
 *      imbalance, and uses the price of THAT swap as a single uniform
 *      clearing price applied to every participant in the batch —
 *      matched and unmatched alike.
 *   3. Redistributes the value saved by netting (and a small surcharge on
 *      oversized "toxic-flow" orders) back to LPs and to the batch's
 *      smaller participants, instead of letting it leak to whichever
 *      searcher reorders transactions first.
 *   4. Scales the batch window with realized volatility — calmer markets
 *      settle faster (lower latency cost), volatile markets batch longer
 *      (higher sandwich-risk windows get more protection).
 *
 * A JIT-liquidity deterrent (short mint→burn lockout) is layered on top
 * since JIT and sandwich attacks share the same "reposition around a
 * known trade" root cause.
 *
 *
 * WHY THIS ARCHITECTURE (read before assuming it's wrong)
 *
 * A single hook contract cannot reorder OTHER PEOPLE'S transactions in a
 * block — that's the block builder's job, not the pool's. So this hook
 * does not attempt "randomize ordering." Instead it makes ordering
 * economically irrelevant *within a batch* by giving every participant
 * the same clearing price, which is the on-chain-achievable version of
 * "neutralize sandwiching" (the same idea behind CoW Protocol's batch
 * auctions and TWAMM, adapted to run as a self-contained hook with no
 * off-chain infrastructure required for the core mechanism).
 *
 * The companion `/resolver` off-chain service adds a *real* Flashbots
 * Protect / CoW Protocol touchpoint for flagged toxic-sized orders before
 * they ever reach this contract — see resolver/README.md.
 *
 *
 */
import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";

contract EssentialsHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    // Errors
    error ExactOutputNotSupported();
    error BatchNotReady();
    error EmptyBatch();
    error BatchFull();
    error JitCooldownActive();
    error ZeroAmount();

    // Config (immutable-ish; owner is the deployer, single-purpose demo)

    /// @notice Minimum / maximum batch window, in blocks. Actual window is
    /// scaled between these bounds based on realized volatility.
    uint256 public constant MIN_WINDOW_BLOCKS = 2;
    uint256 public constant MAX_WINDOW_BLOCKS = 20;

    uint256 public constant MAX_BATCH_SIZE = 75;

    /// @notice Tick-move threshold (absolute) that is considered "1 unit"
    /// of volatility for window-scaling purposes.
    int24 public constant VOL_TICK_UNIT = 10;

    /// @notice Liquidity must sit for this many blocks before it can be
    /// removed without tripping the JIT deterrent.
    uint256 public constant JIT_LOCK_BLOCKS = 3;

    /// @notice An order is flagged "toxic-sized" (and pays a small
    /// surcharge redistributed to the rest of the batch) once it exceeds
    /// this fraction of the batch's total same-direction volume, in bps.
    uint256 public constant TOXIC_SHARE_OF_SIDE_BPS = 5000; // >50% of its side

    /// @notice Surcharge applied to the toxic-flagged portion, in bps of
    /// that order's input amount. Fully redistributed — this contract
    /// keeps nothing.
    uint256 public constant TOXIC_SURCHARGE_BPS = 30; // 0.30%

    /// @notice Split of the toxic surcharge + netting-surplus dust that
    /// goes to LPs via `donate()`. The remainder is redistributed pro-rata
    /// to the non-toxic orders in the same batch (the "restorative" leg).
    uint256 public constant LP_RECAPTURE_SHARE_BPS = 5000; // 50%

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // State

    struct QueuedOrder {
        address trader;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minAmountOut;
    }

    struct BatchState {
        uint256 startBlock;
        uint256 windowBlocks;
        uint256 totalIn0; // total token0 queued from zeroForOne orders
        uint256 totalIn1; // total token1 queued from oneForZero orders
    }

    mapping(PoolId => BatchState) public batches;
    mapping(PoolId => QueuedOrder[]) internal orderQueue;

    /// @dev last observed tick per pool, for volatility-scaled windows
    mapping(PoolId => int24) public lastObservedTick;

    /// @dev JIT tracking: keccak(poolId, owner, tickLower, tickUpper, salt) => block liquidity was added
    mapping(bytes32 => uint256) public liquidityAddedAtBlock;

    // ─────────────────────────────────────────────────────────────────
    // Events — the frontend/indexer reads these directly
    // ─────────────────────────────────────────────────────────────────

    event OrderQueued(
        PoolId indexed poolId, address indexed trader, bool zeroForOne, uint256 amountIn, uint256 batchStartBlock
    );
    event BatchSettled(
        PoolId indexed poolId,
        uint256 ordersCleared,
        uint256 totalIn0,
        uint256 totalIn1,
        uint256 residualSwapAmountIn,
        bool residualZeroForOne,
        uint256 clearingPriceX96,
        uint256 lpRecapture0,
        uint256 lpRecapture1,
        uint256 nextWindowBlocks
    );
    event ToxicOrderFlagged(PoolId indexed poolId, address indexed trader, uint256 amountIn, uint256 surcharge);
    event JitBlocked(PoolId indexed poolId, address indexed lp, uint256 blocksRemaining);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // afterInitialize — seed the volatility tracker and first window

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        lastObservedTick[poolId] = tick;
        batches[poolId].windowBlocks = MIN_WINDOW_BLOCKS;
        return IHooks.afterInitialize.selector;
    }

    // beforeSwap — queue the order instead of executing it (NoOp swap)

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn == 0) revert ZeroAmount();

        PoolId poolId = key.toId();
        BatchState storage batch = batches[poolId];

        // If a previous batch's window has elapsed and nobody called
        // settleBatch() in time, force-settle it now rather than silently
        // discarding it. `_beforeSwap` already executes inside an active
        // PoolManager unlock (the router's), so `_settle` can be called
        // directly here without a second `manager.unlock()`
        bool batchExpired = batch.startBlock != 0 && block.number > batch.startBlock + batch.windowBlocks;
        if (batchExpired) {
            if (orderQueue[poolId].length > 0) {
                _settle(key);
            } else {
                // defensive: shouldn't be reachable (a nonzero startBlock
                // always came with at least one queued order), but never
                // leave a stale, empty batch marker lying around either.
                batch.startBlock = 0;
            }
        }

        // Open a fresh batch if none is currently active (either this was
        // the very first swap for this pool, or the block above just
        // settled and reset the previous one).
        if (batch.startBlock == 0) {
            batch.startBlock = block.number;
            batch.totalIn0 = 0;
            batch.totalIn1 = 0;
        }

        (address trader, uint128 minAmountOut) = _decodeTrader(sender, hookData);

        // enforce the batch size cap before taking any
        // custody of funds, so a rejected order (batch already full)
        // reverts cleanly with no side effects.
        if (orderQueue[poolId].length >= MAX_BATCH_SIZE) revert BatchFull();

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Pull the input into hook custody now. The router's post-swap
        // settlement will true this up against the trader's wallet — see
        // header note on why this is safe (mirrors the pattern used by
        // v4-core's own CustomCurveHook test fixture).
        manager.take(inputCurrency, address(this), amountIn);

        if (params.zeroForOne) {
            batch.totalIn0 += amountIn;
        } else {
            batch.totalIn1 += amountIn;
        }

        orderQueue[poolId].push(
            QueuedOrder({
                trader: trader,
                zeroForOne: params.zeroForOne,
                amountIn: uint128(amountIn),
                minAmountOut: minAmountOut
            })
        );

        emit OrderQueued(poolId, trader, params.zeroForOne, amountIn, batch.startBlock);

        // Fully offset the swap: pool curve is untouched, swapper receives
        // nothing yet (output arrives when the batch settles).
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function _decodeTrader(address sender, bytes calldata hookData) internal pure returns (address, uint128) {
        if (hookData.length >= 64) {
            (address traderAndMin, uint128 minOut) = abi.decode(hookData, (address, uint128));
            return (traderAndMin == address(0) ? sender : traderAndMin, minOut);
        }
        if (hookData.length >= 32) {
            address traderOnly = abi.decode(hookData, (address));
            return (traderOnly == address(0) ? sender : traderOnly, 0);
        }
        return (sender, 0);
    }

    // settleBatch — the auction. Permissionless; anyone can settle once
    // the window has elapsed (keeper-friendly, censorship-resistant).

    function isBatchReady(PoolKey calldata key) external view returns (bool) {
        PoolId poolId = key.toId();
        BatchState storage batch = batches[poolId];
        return orderQueue[poolId].length > 0 && block.number > batch.startBlock + batch.windowBlocks;
    }

    error SettlementReentrancy();

    bool private _settling;

    modifier nonReentrantSettle() {
        if (_settling) revert SettlementReentrancy();
        _settling = true;
        _;
        _settling = false;
    }

    function settleBatch(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        BatchState storage batch = batches[poolId];
        if (orderQueue[poolId].length == 0) revert EmptyBatch();
        if (block.number <= batch.startBlock + batch.windowBlocks) revert BatchNotReady();

        manager.unlock(abi.encode(key));
    }

    /// @dev Only the PoolManager may call back into us, and only while we
    /// are mid-settlement (guarded by BaseHook's unlockCallback plumbing).
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        _settle(key);
        return "";
    }

    /// @dev Working figures for a single settlement, split out to a struct
    /// purely to keep stack depth low across the helper functions below.
    struct SettleCtx {
        uint256 n;
        uint256 surcharge0;
        uint256 surcharge1;
        uint256 nonToxicIn0;
        uint256 nonToxicIn1;
        uint256 netIn0;
        uint256 netIn1;
        bool residualZeroForOne;
        uint256 residualAmountIn;
        uint256 actualResidualIn; // real amount consumed by the residual swap; may be < residualAmountIn under thin liquidity (partial fill) even with an unconstrained price limit -- see _sizeAndExecuteResidual
        uint256 outAmt;
        uint256 token0Pool;
        uint256 token1Pool;
        uint256 clearingPriceX96;
        bool[] isToxic;
    }

    function _settle(PoolKey memory key) internal nonReentrantSettle {
        PoolId poolId = key.toId();
        QueuedOrder[] storage queue = orderQueue[poolId];
        BatchState storage batch = batches[poolId];

        SettleCtx memory ctx;
        ctx.n = queue.length;

        _flagToxicOrders(queue, batch, poolId, ctx);
        _sizeAndExecuteResidual(key, poolId, ctx);
        _payoutParticipants(key, queue, ctx);
        _recapture(key, queue, ctx);
        uint256 nextWindow = _nextWindow(poolId);

        emit BatchSettled(
            poolId,
            ctx.n,
            batch.totalIn0,
            batch.totalIn1,
            ctx.residualAmountIn,
            ctx.residualZeroForOne,
            ctx.clearingPriceX96,
            (key.currency0.balanceOfSelf() * LP_RECAPTURE_SHARE_BPS) / BPS_DENOMINATOR,
            (key.currency1.balanceOfSelf() * LP_RECAPTURE_SHARE_BPS) / BPS_DENOMINATOR,
            nextWindow
        );

        delete orderQueue[poolId];
        batch.startBlock = 0;
        batch.totalIn0 = 0;
        batch.totalIn1 = 0;
        batch.windowBlocks = nextWindow;
    }

    /// Step 1: flag toxic-sized orders, deduct + tally their surcharge.

    function _flagToxicOrders(
        QueuedOrder[] storage queue,
        BatchState storage batch,
        PoolId poolId,
        SettleCtx memory ctx
    ) internal {
        ctx.isToxic = new bool[](ctx.n);
        uint256[] memory originalAmounts = new uint256[](ctx.n);
        for (uint256 i = 0; i < ctx.n; i++) {
            originalAmounts[i] = queue[i].amountIn;
        }

        for (uint256 i = 0; i < ctx.n; i++) {
            QueuedOrder storage o = queue[i];
            uint256 sideTotal = o.zeroForOne ? batch.totalIn0 : batch.totalIn1;

            uint256 traderSideTotal;
            for (uint256 j = 0; j < ctx.n; j++) {
                if (queue[j].zeroForOne == o.zeroForOne && queue[j].trader == o.trader) {
                    traderSideTotal += originalAmounts[j];
                }
            }

            if (sideTotal > 0 && (traderSideTotal * BPS_DENOMINATOR) / sideTotal >= TOXIC_SHARE_OF_SIDE_BPS) {
                ctx.isToxic[i] = true;
            }
        }

        for (uint256 i = 0; i < ctx.n; i++) {
            QueuedOrder storage o = queue[i];
            if (ctx.isToxic[i]) {
                uint256 fee = (originalAmounts[i] * TOXIC_SURCHARGE_BPS) / BPS_DENOMINATOR;
                if (fee > 0) {
                    o.amountIn -= uint128(fee);
                    if (o.zeroForOne) ctx.surcharge0 += fee;
                    else ctx.surcharge1 += fee;
                    emit ToxicOrderFlagged(poolId, o.trader, o.amountIn, fee);
                } else {
                    ctx.isToxic[i] = false; // fee rounds to 0 -- don't exclude this order from bonus eligibility below
                }
            }
            if (!ctx.isToxic[i]) {
                if (o.zeroForOne) ctx.nonToxicIn0 += o.amountIn;
                else ctx.nonToxicIn1 += o.amountIn;
            }
        }

        ctx.netIn0 = batch.totalIn0 - ctx.surcharge0;
        ctx.netIn1 = batch.totalIn1 - ctx.surcharge1;
    }

    /// Steps 2-3: size the residual against spot price, execute it, and
    /// derive the two conservation-safe payout pools.
    function _sizeAndExecuteResidual(PoolKey memory key, PoolId poolId, SettleCtx memory ctx) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        uint256 in0ValueInToken1 = FullMath.mulDiv(ctx.netIn0, priceX96, FixedPoint96.Q96);

        if (in0ValueInToken1 > ctx.netIn1) {
            uint256 excessValueInToken1 = in0ValueInToken1 - ctx.netIn1;
            ctx.residualAmountIn = priceX96 == 0 ? 0 : FullMath.mulDiv(excessValueInToken1, FixedPoint96.Q96, priceX96);
            ctx.residualZeroForOne = true;
        } else if (ctx.netIn1 > in0ValueInToken1) {
            ctx.residualAmountIn = ctx.netIn1 - in0ValueInToken1;
            ctx.residualZeroForOne = false;
        }

        if (ctx.residualAmountIn > 0) {
            BalanceDelta swapDelta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: ctx.residualZeroForOne,
                    amountSpecified: -int256(ctx.residualAmountIn),
                    sqrtPriceLimitX96: ctx.residualZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            _payPoolManager(key, ctx.residualZeroForOne, swapDelta);

            // Use the swap's ACTUAL delta, not the requested
            // residualAmountIn, to derive the payout pools below. Even
            // with an unconstrained price limit, a swap can still only
            // partially fill if the pool's liquidity runs out before the
            // full requested amount is absorbed (e.g. right after heavy
            // JIT liquidity churn) -- using the requested amount in that
            // case would silently leave the difference stranded as
            // "dust" that never gets redistributed. Caught by this
            // project's invariant test suite, not by any single
            // hand-picked scenario.
            int256 amount0 = swapDelta.amount0();
            int256 amount1 = swapDelta.amount1();
            if (ctx.residualZeroForOne) {
                ctx.actualResidualIn = uint256(-amount0);
                ctx.outAmt = uint256(amount1);
            } else {
                ctx.actualResidualIn = uint256(-amount1);
                ctx.outAmt = uint256(amount0);
            }
        }

        ctx.token1Pool = ctx.residualAmountIn == 0
            ? ctx.netIn1
            : (ctx.residualZeroForOne ? ctx.netIn1 + ctx.outAmt : ctx.netIn1 - ctx.actualResidualIn);
        ctx.token0Pool = ctx.residualAmountIn == 0
            ? ctx.netIn0
            : (ctx.residualZeroForOne ? ctx.netIn0 - ctx.actualResidualIn : ctx.netIn0 + ctx.outAmt);
        ctx.clearingPriceX96 = ctx.netIn0 > 0 ? FullMath.mulDiv(ctx.token1Pool, FixedPoint96.Q96, ctx.netIn0) : priceX96;
    }

    /// Step 4: pro-rata payout from the two conservation-safe pools.
    function _payoutParticipants(PoolKey memory key, QueuedOrder[] storage queue, SettleCtx memory ctx) internal {
        for (uint256 i = 0; i < ctx.n; i++) {
            QueuedOrder storage o = queue[i];
            if (o.zeroForOne) {
                if (ctx.netIn0 > 0 && ctx.token1Pool > 0) {
                    uint256 out = FullMath.mulDiv(ctx.token1Pool, o.amountIn, ctx.netIn0);
                    if (out > 0) key.currency1.transfer(o.trader, out);
                }
            } else {
                if (ctx.netIn1 > 0 && ctx.token0Pool > 0) {
                    uint256 out = FullMath.mulDiv(ctx.token0Pool, o.amountIn, ctx.netIn1);
                    if (out > 0) key.currency0.transfer(o.trader, out);
                }
            }
        }
    }

    /// Step 5: surcharge + rounding dust -> LPs (donate) + non-toxic orders.

    function _recapture(PoolKey memory key, QueuedOrder[] storage queue, SettleCtx memory ctx) internal {
        uint256 dust0 = key.currency0.balanceOfSelf();
        uint256 dust1 = key.currency1.balanceOfSelf();

        uint256 lp0 = (dust0 * LP_RECAPTURE_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 lp1 = (dust1 * LP_RECAPTURE_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 bonusPool0 = dust0 - lp0;
        uint256 bonusPool1 = dust1 - lp1;

        // no zeroForOne-side non-toxic recipient exists for a currency1
        // bonus, and vice versa -- redirect to LPs instead of stranding it.
        if (bonusPool1 > 0 && ctx.nonToxicIn0 == 0) {
            lp1 += bonusPool1;
            bonusPool1 = 0;
        }
        if (bonusPool0 > 0 && ctx.nonToxicIn1 == 0) {
            lp0 += bonusPool0;
            bonusPool0 = 0;
        }

        if (lp0 > 0 || lp1 > 0) {
            manager.donate(key, lp0, lp1, "");
            if (lp0 > 0) key.currency0.settle(manager, address(this), lp0, false);
            if (lp1 > 0) key.currency1.settle(manager, address(this), lp1, false);
        }

        if (bonusPool0 > 0 || bonusPool1 > 0) {
            for (uint256 i = 0; i < ctx.n; i++) {
                if (ctx.isToxic[i]) continue;
                QueuedOrder storage o = queue[i];
                if (o.zeroForOne && bonusPool1 > 0 && ctx.nonToxicIn0 > 0) {
                    uint256 bonus = FullMath.mulDiv(bonusPool1, o.amountIn, ctx.nonToxicIn0);
                    if (bonus > 0) key.currency1.transfer(o.trader, bonus);
                } else if (!o.zeroForOne && bonusPool0 > 0 && ctx.nonToxicIn1 > 0) {
                    uint256 bonus = FullMath.mulDiv(bonusPool0, o.amountIn, ctx.nonToxicIn1);
                    if (bonus > 0) key.currency0.transfer(o.trader, bonus);
                }
            }
        }
    }

    /// Step 6: volatility-scaled window for the pool's *next* batch.
    function _nextWindow(PoolId poolId) internal returns (uint256 nextWindow) {
        (, int24 tickNow,,) = manager.getSlot0(poolId);
        int24 prevTick = lastObservedTick[poolId];
        int24 tickMove = tickNow > prevTick ? tickNow - prevTick : prevTick - tickNow;
        lastObservedTick[poolId] = tickNow;

        uint256 volUnits = uint256(int256(tickMove)) / uint256(uint24(VOL_TICK_UNIT));
        nextWindow = MIN_WINDOW_BLOCKS + volUnits;
        if (nextWindow > MAX_WINDOW_BLOCKS) nextWindow = MAX_WINDOW_BLOCKS;
        if (nextWindow < MIN_WINDOW_BLOCKS) nextWindow = MIN_WINDOW_BLOCKS;
    }

    /// @dev Settle this contract's own delta with the PoolManager after a
    /// swap it initiated directly (as opposed to the take()-funded queue
    /// step, which nets out via the router's own settlement).
    function _payPoolManager(PoolKey memory key, bool, BalanceDelta delta) internal {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        if (amount0 < 0) {
            key.currency0.settle(manager, address(this), uint256(-amount0), false);
        } else if (amount0 > 0) {
            key.currency0.take(manager, address(this), uint256(amount0), false);
        }
        if (amount1 < 0) {
            key.currency1.settle(manager, address(this), uint256(-amount1), false);
        } else if (amount1 > 0) {
            key.currency1.take(manager, address(this), uint256(amount1), false);
        }
    }

    // JIT liquidity deterrent

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 posKey = _positionKey(key.toId(), sender, params.tickLower, params.tickUpper, params.salt);
        liquidityAddedAtBlock[posKey] = block.number;
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 posKey = _positionKey(key.toId(), sender, params.tickLower, params.tickUpper, params.salt);
        uint256 addedAt = liquidityAddedAtBlock[posKey];
        if (addedAt != 0 && block.number < addedAt + JIT_LOCK_BLOCKS) {
            emit JitBlocked(key.toId(), sender, (addedAt + JIT_LOCK_BLOCKS) - block.number);
            revert JitCooldownActive();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _positionKey(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, owner, tickLower, tickUpper, salt));
    }

    // Getter/View helper functions

    function getQueueLength(PoolKey calldata key) external view returns (uint256) {
        return orderQueue[key.toId()].length;
    }

    function getBatch(PoolKey calldata key) external view returns (BatchState memory) {
        return batches[key.toId()];
    }

    function getQueuedOrder(PoolKey calldata key, uint256 index) external view returns (QueuedOrder memory) {
        return orderQueue[key.toId()][index];
    }
}
