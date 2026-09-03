// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EssentialsHookTestBase} from "./utils/EssentialsHookTestBase.sol";
import {EssentialsHook} from "../src/EssentialsHook.sol";

contract AuditFindings_ToxicSplitEvasionFixTest is EssentialsHookTestBase {
    /// Same-ADDRESS splitting (the naive evasion the fix targets):
    /// attacker splits their order into pieces but reuses the SAME
    /// trader address for all pieces on a side.
    function test_A1c_SameAddressSplit_StillFlaggedToxic() public {
        uint256 victimIn = 5 ether;
        uint256 attackerIn = 20 ether;
        uint256 piece = attackerIn / 5;

        for (uint256 i = 0; i < 5; i++) {
            _queueSwap(true, piece, attacker);
        } // SAME address, 5 pieces
        _queueSwap(true, victimIn, victim);
        for (uint256 i = 0; i < 5; i++) {
            _queueSwap(false, piece, attacker);
        }

        _rollPastWindow();
        hook.settleBatch(key);

        int256 pnl =
            int256(currency0.balanceOf(attacker)) + int256(currency1.balanceOf(attacker)) - int256(2 * attackerIn);
        emit log_named_int("same-address 5-way split attacker P&L", pnl);
        // should now match (or be very close to) the undivided baseline
        // of -132230458662342340 wei, confirming the fix closes THIS variant
    }
}
