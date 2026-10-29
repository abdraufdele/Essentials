// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "../src/libraries/CurrencySettler.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

interface INativeClaims {
    function claimable(Currency currency, address trader) external view returns (uint256);
    function claim(Currency currency, address recipient) external;
}

contract NativeSettlementIsolationTest is EssentialsHookTestBase {
    function _nativePool() internal returns (PoolKey memory nativePool) {
        vm.deal(address(this), 10 ether);
        (nativePool,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)), currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
    }

    function test_ExplicitSettlementIsolatesNativeRecipientAccounting() public {
        PoolKey memory nativePool = _nativePool();
        AccountingRecipient recipient = new AccountingRecipient(manager);
        _queueSwapOn(nativePool, false, 0.001 ether, address(recipient));
        _queueSwapOn(nativePool, false, 0.001 ether, alice);
        _rollPastWindowOn(nativePool);
        hook.settleBatch(nativePool);
        assertEq(hook.getQueueLength(nativePool), 0);
        assertGt(alice.balance, 0);
        uint256 owed = INativeClaims(address(hook)).claimable(Currency.wrap(address(0)), address(recipient));
        assertGt(owed, 0, "unsuccessful native delivery remains claimable");
        recipient.redirect(address(hook), bob);
        assertEq(bob.balance, owed);
    }

    function test_ExpiredSettlementDefersNativeDeliveryUntilClaim() public {
        PoolKey memory nativePool = _nativePool();
        AccountingRecipient recipient = new AccountingRecipient(manager);
        _queueSwapOn(nativePool, false, 0.001 ether, address(recipient));
        _queueSwapOn(nativePool, false, 0.001 ether, alice);
        _rollPastWindowOn(nativePool);
        _queueSwapOn(nativePool, false, 0.001 ether, bob);
        assertEq(hook.getQueueLength(nativePool), 1, "new batch remains usable");
        INativeClaims claims = INativeClaims(address(hook));
        uint256 owed = claims.claimable(Currency.wrap(address(0)), alice);
        assertGt(owed, 0);
        vm.prank(alice);
        claims.claim(Currency.wrap(address(0)), alice);
        assertEq(alice.balance, owed);
    }

    function test_NativePaymentResetsManagerSyncCurrency() public {
        _nativePool();
        NativeSettlementHarness harness = new NativeSettlementHarness(manager, currency1);
        uint256 reserves = address(manager).balance;
        harness.run();
        assertEq(address(manager).balance, reserves);
        assertEq(address(harness).balance, 0);
    }

    function _callbackPool()
        internal
        returns (PoolKey memory callbackPool, AccountingCallbackToken token, bool tokenFirst)
    {
        token = new AccountingCallbackToken(manager);
        token.mint(address(this), 1_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenFirst = address(token) < Currency.unwrap(currency0);
        (callbackPool,) = initPoolAndAddLiquidity(
            tokenFirst ? Currency.wrap(address(token)) : currency0,
            tokenFirst ? currency0 : Currency.wrap(address(token)),
            IHooks(address(hook)),
            500,
            SQRT_PRICE_1_1
        );
        seedMoreLiquidity(callbackPool, 100 ether, 100 ether);
        token.setCallbackRecipient(attacker);
    }

    function test_ExplicitSettlementIsolatesTokenRecipientAccounting() public {
        (PoolKey memory callbackPool, AccountingCallbackToken token, bool tokenFirst) = _callbackPool();
        _queueSwapOn(callbackPool, !tokenFirst, 0.001 ether, attacker);
        _queueSwapOn(callbackPool, !tokenFirst, 0.001 ether, alice);
        _rollPastWindowOn(callbackPool);
        hook.settleBatch(callbackPool);
        assertEq(hook.getQueueLength(callbackPool), 0);
        assertGt(token.balanceOf(alice), 0);
        Currency output = Currency.wrap(address(token));
        uint256 owed = INativeClaims(address(hook)).claimable(output, attacker);
        assertGt(owed, 0);
        vm.prank(attacker);
        INativeClaims(address(hook)).claim(output, bob);
        assertEq(token.balanceOf(bob), owed);
    }

    function test_ExpiredSettlementDefersTokenRecipientCallbacks() public {
        (PoolKey memory callbackPool, AccountingCallbackToken token, bool tokenFirst) = _callbackPool();
        _queueSwapOn(callbackPool, !tokenFirst, 0.001 ether, attacker);
        _queueSwapOn(callbackPool, !tokenFirst, 0.001 ether, alice);
        _rollPastWindowOn(callbackPool);
        _queueSwapOn(callbackPool, !tokenFirst, 0.001 ether, carol);
        assertEq(hook.getQueueLength(callbackPool), 1);
        Currency output = Currency.wrap(address(token));
        uint256 owed = INativeClaims(address(hook)).claimable(output, alice);
        assertGt(owed, 0);
        vm.prank(alice);
        INativeClaims(address(hook)).claim(output, alice);
        assertEq(token.balanceOf(alice), owed);
    }
}

contract AccountingRecipient {
    IPoolManager immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    receive() external payable {
        if (msg.sender != address(manager)) manager.take(Currency.wrap(address(0)), address(this), 1);
    }

    function redirect(address hook, address recipient) external {
        INativeClaims(hook).claim(Currency.wrap(address(0)), recipient);
    }
}

contract NativeSettlementHarness {
    using CurrencySettler for Currency;

    IPoolManager immutable manager;
    Currency immutable token;

    constructor(IPoolManager poolManager, Currency syncedToken) {
        manager = poolManager;
        token = syncedToken;
    }

    receive() external payable {}

    function run() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        manager.take(Currency.wrap(address(0)), address(this), 1);
        manager.sync(token);
        Currency.wrap(address(0)).settle(manager, address(this), 1, false);
        return "";
    }
}

contract AccountingCallbackToken is MockERC20 {
    IPoolManager immutable manager;
    address public callbackRecipient;

    constructor(IPoolManager poolManager) MockERC20("Accounting callback", "ACT", 18) {
        manager = poolManager;
    }

    function setCallbackRecipient(address recipient) external {
        callbackRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (to == callbackRecipient) manager.mint(address(this), uint160(address(this)), 1);
        return true;
    }
}
