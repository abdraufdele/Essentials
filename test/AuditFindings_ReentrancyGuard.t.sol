// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {MaliciousReentrantToken} from "./utils/MaliciousReentrantToken.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

contract AuditFindings_ReentrancyGuardTest is EssentialsHookTestBase {
    function test_A2_ReentrantTokenDuringPayout() public {
        MaliciousReentrantToken evil = new MaliciousReentrantToken();
        // ensure evil token address ordering vs currency0 for a valid PoolKey
        Currency evilCurrency = Currency.wrap(address(evil));
        Currency otherCurrency = currency0;
        PoolKey memory evilKey;
        bool evilIsCurrency0 = address(evil) < Currency.unwrap(otherCurrency);
        if (evilIsCurrency0) {
            evilKey = PoolKey({
                currency0: evilCurrency,
                currency1: otherCurrency,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
        } else {
            evilKey = PoolKey({
                currency0: otherCurrency,
                currency1: evilCurrency,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
        }

        manager.initialize(evilKey, SQRT_PRICE_1_1);

        evil.mint(address(this), 1000 ether);
        evil.approve(address(modifyLiquidityRouter), type(uint256).max);
        evil.approve(address(swapRouter), type(uint256).max);
        MockERC20Approve(otherCurrency);

        modifyLiquidityRouter.modifyLiquidity(evilKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        // LIQUIDITY_PARAMS' liquidityDelta is an L-unit, not a token
        // amount (see EssentialsHook.sol audit notes) -- add a lot more
        // raw L so the pool has enough real token depth for the swap
        // sizes below; this test is about reentrancy, not depth.
        IPoolManager.ModifyLiquidityParams memory deepAdd = IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 500 ether,
            salt: bytes32(uint256(7))
        });
        modifyLiquidityRouter.modifyLiquidity(evilKey, deepAdd, ZERO_BYTES);

        // attacker queues an order that will be PAID OUT in the evil
        // token (i.e. attacker sells the OTHER currency for evil token),
        // so the payout loop's transfer() call is on the malicious
        // token's contract -- the exact call CurrencySettler/the payout
        // loop makes.
        bool attackerSellsOther = evilIsCurrency0 ? false : true; // sell `otherCurrency` so payout is in evil token

        _queueSwapOn(evilKey, attackerSellsOther, 0.05 ether, attacker);
        _queueSwapOn(evilKey, !attackerSellsOther, 0.05 ether, victim);

        // arm AFTER queueing (not before) so the one-shot reentrancy
        // attempt fires specifically during settlement's PAYOUT transfer,
        // not during queueing's take() call.
        evil.arm(hook, evilKey);

        _rollPastWindowOn(evilKey);

        hook.settleBatch(evilKey);

        emit log_named_uint("reentrancy attempts made", evil.attempts());
        emit log_named_uint("reentrancy succeeded (1=yes,0=no)", evil.reentrySucceeded() ? 1 : 0);
        if (!evil.reentrySucceeded()) {
            emit log_bytes(evil.reentryRevertData());
        }

        // if the reentrant settleBatch() call succeeded, that means a
        // SECOND settlement pass ran on a batch/queue that the outer,
        // still-executing settlement had not yet cleared -- which would
        // mean double payout / double surcharge deduction. Assert it did
        // NOT succeed as the confirmatory check.
        assertFalse(evil.reentrySucceeded(), "CRITICAL: reentrant settleBatch() succeeded mid-settlement");
    }

    function MockERC20Approve(Currency c) internal {
        // approve the OTHER (non-evil) currency for the router too
        (bool ok,) = Currency.unwrap(c).call(
            abi.encodeWithSignature("approve(address,uint256)", address(modifyLiquidityRouter), type(uint256).max)
        );
        require(ok, "approve failed");
    }
}
