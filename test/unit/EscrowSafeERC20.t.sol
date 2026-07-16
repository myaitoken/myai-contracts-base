// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../../contracts/Escrow.sol";

contract GoodToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a; balanceOf[to] += a;
    }
    function transferFrom(address f, address to, uint256 a) external {
        balanceOf[f] -= a; balanceOf[to] += a;
    }
}

contract FalseToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return false; }
}

/// @notice Audit #9711 (PRE-AUDIT, not deployed on-chain): Escrow.sol must move
///         tokens via OZ SafeERC20 so non-standard tokens do not silently break.
contract EscrowSafeERC20Test is Test {
    address treasury = address(0x7777);
    address agent    = address(0xA);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant JOB = keccak256("job-1");
    uint256 constant AMT = 1000 ether; // provider 970, burn 15, fee 15

    function test_standardToken_fullFlow() public {
        GoodToken t = new GoodToken();
        Escrow e = new Escrow(address(t), treasury);
        t.mint(address(this), AMT);
        e.deposit(JOB, agent, AMT);
        assertEq(t.balanceOf(address(e)), AMT);
        e.release(JOB, bytes32("poc"));
        assertEq(t.balanceOf(agent), 970 ether);
        assertEq(t.balanceOf(DEAD), 15 ether);
        assertEq(t.balanceOf(treasury), 15 ether);
        assertEq(t.balanceOf(address(e)), 0);
    }

    function test_nonReturningToken_depositAndRelease() public {
        NoReturnToken t = new NoReturnToken();
        Escrow e = new Escrow(address(t), treasury);
        t.mint(address(this), AMT);
        e.deposit(JOB, agent, AMT);
        assertEq(t.balanceOf(address(e)), AMT);
        e.release(JOB, bytes32("poc"));
        assertEq(t.balanceOf(agent), 970 ether);
        assertEq(t.balanceOf(DEAD), 15 ether);
        assertEq(t.balanceOf(treasury), 15 ether);
    }

    function test_nonReturningToken_refundPath() public {
        NoReturnToken t = new NoReturnToken();
        Escrow e = new Escrow(address(t), treasury);
        t.mint(address(this), AMT);
        e.deposit(JOB, agent, AMT);
        e.refund(JOB);
        assertEq(t.balanceOf(address(this)), AMT);
        assertEq(t.balanceOf(address(e)), 0);
    }

    function test_falseReturningToken_depositReverts() public {
        FalseToken t = new FalseToken();
        Escrow e = new Escrow(address(t), treasury);
        t.mint(address(this), AMT);
        vm.expectRevert();
        e.deposit(JOB, agent, AMT);
    }
}
