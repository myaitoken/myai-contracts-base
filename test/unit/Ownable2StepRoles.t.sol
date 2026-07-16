// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIEscrow} from "../../contracts/MyAIEscrow.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @notice Audit #9710 (PRE-AUDIT, not deployed on-chain): privileged suite
///         contracts must use two-step ownership so a mistyped transfer cannot
///         permanently brick the owner role.
contract Ownable2StepRolesTest is Test {
    MyAIEscrow escrow;
    MyAIReputation rep;
    MockERC20 token;

    address coordinator = address(0xC0);
    address treasury    = address(0x7);
    address newOwner    = address(0xBEEF);
    address stranger    = address(0xBAD);

    function setUp() public {
        token  = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        escrow = new MyAIEscrow(address(token), coordinator, treasury);
        rep    = new MyAIReputation(coordinator, address(token));
    }

    // ─── MyAIEscrow ──────────────────────────────────────────────────────────

    function test_escrow_transferIsTwoStep() public {
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), address(this));   // not transferred yet
        assertEq(escrow.pendingOwner(), newOwner);
    }

    function test_escrow_acceptCompletes() public {
        escrow.transferOwnership(newOwner);
        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
        assertEq(escrow.pendingOwner(), address(0));
    }

    function test_escrow_nonPendingCannotAccept() public {
        escrow.transferOwnership(newOwner);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        escrow.acceptOwnership();
        assertEq(escrow.owner(), address(this));
    }

    /// @dev The core of the finding: a fat-fingered transfer is recoverable.
    function test_escrow_mistypedTransferIsRecoverable() public {
        escrow.transferOwnership(address(0xDEAD)); // wrong address, never accepts
        assertEq(escrow.owner(), address(this));   // ownership NOT lost
        escrow.transferOwnership(newOwner);        // redirect to the right one
        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
    }

    // ─── MyAIReputation ──────────────────────────────────────────────────────

    function test_rep_transferIsTwoStep() public {
        rep.transferOwnership(newOwner);
        assertEq(rep.owner(), address(this));
        assertEq(rep.pendingOwner(), newOwner);
    }

    function test_rep_acceptCompletes() public {
        rep.transferOwnership(newOwner);
        vm.prank(newOwner);
        rep.acceptOwnership();
        assertEq(rep.owner(), newOwner);
        assertEq(rep.pendingOwner(), address(0));
    }

    function test_rep_nonPendingCannotAccept() public {
        rep.transferOwnership(newOwner);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        rep.acceptOwnership();
        assertEq(rep.owner(), address(this));
    }
}
