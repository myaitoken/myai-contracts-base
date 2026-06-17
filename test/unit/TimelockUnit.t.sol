// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAITimelock} from "../../contracts/MyAITimelock.sol";

contract _TLTarget {
    uint256 public x;
    function setX(uint256 v) external { x = v; }
}

/// @notice Unit tests for MyAITimelock (OZ TimelockController wrapper).
contract TimelockUnitTest is Test {
    MyAITimelock public tl;
    _TLTarget public target;
    address proposer = address(0x9001);
    address executor = address(0x9002);
    address stranger = address(0xBAD);

    uint256 constant DELAY = 48 hours;
    bytes32 constant SALT = keccak256("op-1");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        tl = new MyAITimelock(DELAY, proposers, executors, address(this));
        target = new _TLTarget();
    }

    function test_minDelayAndRoles() public view {
        assertEq(tl.getMinDelay(), DELAY);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), proposer));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), executor));
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setX(uint256)", uint256(7));
    }

    function test_scheduleThenExecuteAfterDelay() public {
        vm.prank(proposer);
        tl.schedule(address(target), 0, _data(), bytes32(0), SALT, DELAY);

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(executor);
        tl.execute(address(target), 0, _data(), bytes32(0), SALT);
        assertEq(target.x(), 7);
    }

    function test_executeBeforeDelayReverts() public {
        vm.prank(proposer);
        tl.schedule(address(target), 0, _data(), bytes32(0), SALT, DELAY);
        // not ready (no warp)
        vm.prank(executor);
        vm.expectRevert(); // TimelockUnexpectedOperationState
        tl.execute(address(target), 0, _data(), bytes32(0), SALT);
    }

    function test_scheduleNotProposerReverts() public {
        bytes32 role = tl.PROPOSER_ROLE(); // cache before prank so it isn't consumed
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", stranger, role
            )
        );
        tl.schedule(address(target), 0, _data(), bytes32(0), SALT, DELAY);
    }

    function test_scheduleBelowMinDelayReverts() public {
        vm.prank(proposer);
        vm.expectRevert(); // TimelockInsufficientDelay
        tl.schedule(address(target), 0, _data(), bytes32(0), SALT, DELAY - 1);
    }
}
