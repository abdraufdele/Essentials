// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {EssentialsHook} from "../../src/EssentialsHook.sol";

contract MaliciousReentrantToken {
    string public name = "Evil";
    string public symbol = "EVIL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    EssentialsHook public target;
    PoolKey public targetKey;
    bool public armed;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function arm(EssentialsHook _target, PoolKey memory _key) external {
        target = _target;
        targetKey = _key;
        armed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);

        if (armed) {
            armed = false;
            attempts++;
            try target.settleBatch(targetKey) {
                reentrySucceeded = true;
            } catch (bytes memory reason) {
                reentrySucceeded = false;
                reentryRevertData = reason;
            }
        }
    }
}
