// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

interface IAuditClaims {
    function claimable(Currency currency, address trader) external view returns (uint256);
    function claim(Currency currency, address recipient) external;
    function transferPayout(Currency currency, address recipient, uint256 amount) external;
}

contract AuditSecurityRegressionTest is EssentialsHookTestBase {
    function test_CrossPool_PendingEscrowSurvivesOtherSettlement() public {
        (PoolKey memory other,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(other, 100 ether, 100 ether);
        _queueSwap(true, 1 ether, alice);
        _queueSwapOn(other, true, 5 ether, bob);
        _rollPastWindow();
        hook.settleBatch(key);
        assertGe(currency0.balanceOf(address(hook)), 5 ether, "other batch escrow was spent");
        hook.settleBatch(other);
        assertGt(currency1.balanceOf(bob), 0, "second batch must remain payable");
    }

    function test_PartialFill_ExhaustedLiquidityDoesNotLockPrincipal() public {
        (PoolKey memory thin,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        _queueSwapOn(thin, true, 1 ether, alice);
        _rollPastWindowOn(thin);
        hook.settleBatch(thin);
        assertEq(hook.getQueueLength(thin), 0, "thin pool batch must close");
        assertGt(currency0.balanceOf(alice), 0.9 ether, "unspent input must return to depositor");
    }

    function test_RejectedRecipient_DoesNotBlockHonestBatch() public {
        _queueSwap(true, 1 ether, alice);
        _queueSwap(true, 1 ether, attacker);
        // Models a token with a permanently blocklisted destination.
        vm.mockCallRevert(
            Currency.unwrap(currency1),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, attacker),
            abi.encodeWithSignature("Error(string)", "blocked recipient")
        );
        _rollPastWindow();
        hook.settleBatch(key);
        assertEq(hook.getQueueLength(key), 0, "one destination must not freeze batch");
        assertGt(currency1.balanceOf(alice), 0, "honest participant must be paid");
    }

    function test_NativeOutput_AcceptedTokenOrderCanSettle() public {
        vm.deal(address(this), 10 ether);
        (PoolKey memory nativePool,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)), currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        _queueSwapOn(nativePool, false, 0.001 ether, alice);
        _rollPastWindowOn(nativePool);
        hook.settleBatch(nativePool);
        assertEq(hook.getQueueLength(nativePool), 0);
        assertGt(alice.balance, 0, "native output must be deliverable");
    }

    function test_CrossPool_ReverseSettlementOrderAndUnsolicitedFunds() public {
        (PoolKey memory other,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(other, 100 ether, 100 ether);
        _queueSwap(true, 5 ether, alice);
        _queueSwapOn(other, false, 1 ether, bob);
        // Funds sent outside the queue must not become another batch's revenue.
        deal(Currency.unwrap(currency0), address(hook), currency0.balanceOf(address(hook)) + 3 ether);
        _rollPastWindowOn(other);
        hook.settleBatch(other);
        assertGe(currency0.balanceOf(address(hook)), 8 ether, "escrow and unrelated funds reserved");
        hook.settleBatch(key);
        assertGe(currency0.balanceOf(address(hook)), 3 ether, "unsolicited funds not redistributed");
    }

    function testFuzz_PartialFill_RefundsEitherDirection(bool zeroForOne) public {
        (PoolKey memory thin,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        _queueSwapOn(thin, zeroForOne, 1 ether, alice);
        _rollPastWindowOn(thin);
        hook.settleBatch(thin);
        Currency input = zeroForOne ? currency0 : currency1;
        assertGt(input.balanceOf(alice), 0.9 ether, "unexecuted input refunded");
        assertEq(hook.getQueueLength(thin), 0);
    }

    function test_PartialFill_TwoSidesRetainSourceRefund() public {
        (PoolKey memory thin,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        _queueSwapOn(thin, true, 1 ether, alice);
        _queueSwapOn(thin, false, 0.0001 ether, bob);
        _rollPastWindowOn(thin);
        hook.settleBatch(thin);
        assertGt(currency0.balanceOf(alice), 0.9 ether, "source side owns its unspent input");
        assertGt(currency0.balanceOf(bob), 0, "opposite side still paid");
        assertEq(currency0.balanceOf(address(hook)), 0, "all batch input allocated");
    }

    function test_ZeroLiquidity_ReturnsInputInsteadOfLocking() public {
        (PoolKey memory empty,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        _queueSwapOn(empty, true, 1 ether, alice);
        _rollPastWindowOn(empty);
        hook.settleBatch(empty);
        assertEq(currency0.balanceOf(alice), 1 ether, "no execution means full input returned");
        assertEq(hook.getQueueLength(empty), 0);
    }

    function test_RejectedRecipient_ClaimCanRedirectAndCannotDoubleSpend() public {
        _queueSwap(true, 1 ether, alice);
        _queueSwap(true, 1 ether, attacker);
        vm.mockCallRevert(
            Currency.unwrap(currency1),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, attacker),
            abi.encodeWithSignature("Error(string)", "blocked recipient")
        );
        _rollPastWindow();
        hook.settleBatch(key);
        IAuditClaims claims = IAuditClaims(address(hook));
        uint256 owed = claims.claimable(currency1, attacker);
        assertGt(owed, 0);
        vm.expectRevert();
        vm.prank(bob);
        claims.claim(currency1, bob);
        vm.expectRevert();
        vm.prank(attacker);
        claims.claim(currency1, attacker);
        assertEq(claims.claimable(currency1, attacker), owed, "failed claim remains payable");
        vm.prank(attacker);
        claims.claim(currency1, bob);
        assertEq(currency1.balanceOf(bob), owed);
        assertEq(claims.claimable(currency1, attacker), 0);
        vm.expectRevert();
        vm.prank(attacker);
        claims.claim(currency1, bob);
    }

    function test_PendingClaimSurvivesAnotherPoolSettlement() public {
        (PoolKey memory other,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(other, 100 ether, 100 ether);
        _queueSwap(true, 1 ether, attacker);
        vm.mockCallRevert(
            Currency.unwrap(currency1),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, attacker),
            abi.encodeWithSignature("Error(string)", "blocked recipient")
        );
        _rollPastWindow();
        hook.settleBatch(key);
        IAuditClaims claims = IAuditClaims(address(hook));
        uint256 owed = claims.claimable(currency1, attacker);
        _queueSwapOn(other, false, 1 ether, bob);
        _rollPastWindowOn(other);
        hook.settleBatch(other);
        assertGe(currency1.balanceOf(address(hook)), owed, "claim collateral reserved");
        vm.prank(attacker);
        claims.claim(currency1, carol);
        assertEq(currency1.balanceOf(carol), owed);
    }

    function test_NativeInput_CanQueueAndSettle() public {
        vm.deal(address(this), 10 ether);
        (PoolKey memory nativePool,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)), currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        swapRouter.swap{value: 0.001 ether}(
            nativePool,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(0.001 ether),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            _poolSwapTestSettings(),
            abi.encode(alice)
        );
        _rollPastWindowOn(nativePool);
        hook.settleBatch(nativePool);
        assertGt(currency1.balanceOf(alice), 0);
    }

    function test_RevertingNativeRecipient_DefersAndRedirects() public {
        NativePayoutRecipient rejected = new NativePayoutRecipient(false);
        _nativeRecipientCase(rejected);
    }

    function test_GasBurningNativeRecipient_DefersAndRedirects() public {
        NativePayoutRecipient rejected = new NativePayoutRecipient(true);
        _nativeRecipientCase(rejected);
    }

    function _nativeRecipientCase(NativePayoutRecipient rejected) internal {
        vm.deal(address(this), 10 ether);
        (PoolKey memory nativePool,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)), currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        _queueSwapOn(nativePool, false, 0.001 ether, address(rejected));
        _queueSwapOn(nativePool, false, 0.001 ether, alice);
        _rollPastWindowOn(nativePool);
        hook.settleBatch(nativePool);
        assertGt(alice.balance, 0);
        uint256 owed = IAuditClaims(address(hook)).claimable(Currency.wrap(address(0)), address(rejected));
        assertGt(owed, 0);
        rejected.redirect(address(hook), bob);
        assertEq(bob.balance, owed);
    }

    function test_PayoutHelperCannotBeCalledByAnOutsider() public {
        vm.expectRevert();
        IAuditClaims(address(hook)).transferPayout(currency0, attacker, 1);
    }

    function test_FalseReturnAfterMovement_RollsBackBeforeCreditingClaim() public {
        FalseReturnToken token = new FalseReturnToken();
        token.mint(address(this), 1_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        bool tokenFirst = address(token) < Currency.unwrap(currency0);
        (PoolKey memory restricted,) = initPoolAndAddLiquidity(
            tokenFirst ? Currency.wrap(address(token)) : currency0,
            tokenFirst ? currency0 : Currency.wrap(address(token)),
            IHooks(address(hook)),
            500,
            SQRT_PRICE_1_1
        );
        seedMoreLiquidity(restricted, 100 ether, 100 ether);
        _queueSwapOn(restricted, !tokenFirst, 0.001 ether, attacker);
        token.setRejected(attacker);
        _rollPastWindowOn(restricted);
        hook.settleBatch(restricted);
        Currency output = Currency.wrap(address(token));
        IAuditClaims claims = IAuditClaims(address(hook));
        uint256 owed = claims.claimable(output, attacker);
        assertGt(owed, 0);
        assertEq(token.balanceOf(attacker), 0, "failed helper movement rolled back");
        vm.prank(attacker);
        claims.claim(output, bob);
        assertEq(token.balanceOf(bob), owed);
    }

    function test_AggregateAdmissionLimitPreservesExistingEscrow() public {
        uint256 first = uint256(uint128(type(int128).max));
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), first);
        _queueSwap(true, first, alice);
        uint256 held = currency0.balanceOf(address(hook));
        vm.expectRevert();
        _queueSwap(true, 1, bob);
        assertEq(hook.getQueueLength(key), 1);
        assertEq(currency0.balanceOf(address(hook)), held);
    }
}

contract NativePayoutRecipient {
    bool immutable burnGas;

    constructor(bool burn) {
        burnGas = burn;
    }

    receive() external payable {
        if (burnGas) {
            assembly {
                for {} 1 {} {}
            }
        }
        revert("rejected");
    }

    function redirect(address hook, address recipient) external {
        IAuditClaims(hook).claim(Currency.wrap(address(0)), recipient);
    }
}

contract FalseReturnToken is MockERC20 {
    address public rejected;

    constructor() MockERC20("Restricted", "RST", 18) {}

    function setRejected(address recipient) external {
        rejected = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return to != rejected;
    }
}
