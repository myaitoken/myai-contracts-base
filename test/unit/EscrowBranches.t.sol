// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIEscrow} from "../../contracts/MyAIEscrow.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @notice Negative-path / branch-coverage tests for MyAIEscrow.
/// Targets every require() revert, access-control guard, the whenNotPaused
/// gate, and the fee==0 settlement branch — the paths an auditor checks and
/// that the happy-path unit suite leaves uncovered.
contract EscrowBranchesTest is Test {
    MyAIEscrow public escrow;
    MockERC20 public token;

    address owner;                       // = address(this) (deployer)
    address coordinator = address(0xC00);
    address requester   = address(0xA1);
    address provider    = address(0xB2);
    address treasury    = address(0xCAFE);
    address stranger    = address(0xBAD);

    bytes32 constant JOB = keccak256("job-branch");

    function setUp() public {
        owner = address(this);
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        escrow = new MyAIEscrow(address(token), coordinator, treasury);
        token.transfer(requester, 100_000 ether);
        vm.prank(requester);
        token.approve(address(escrow), type(uint256).max);
    }

    function _lock(uint256 amount) internal {
        vm.prank(requester);
        escrow.lockPayment(JOB, provider, amount);
    }

    function _ownableErr(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", who);
    }

    // ─── Constructor guards ────────────────────────────────────────────────
    function test_ctor_revertsTokenZero() public {
        vm.expectRevert(bytes("Token zero"));
        new MyAIEscrow(address(0), coordinator, treasury);
    }

    function test_ctor_revertsCoordinatorZero() public {
        vm.expectRevert(bytes("Coordinator zero"));
        new MyAIEscrow(address(token), address(0), treasury);
    }

    function test_ctor_revertsTreasuryZero() public {
        vm.expectRevert(bytes("Treasury zero"));
        new MyAIEscrow(address(token), coordinator, address(0));
    }

    // ─── lockPayment guards ────────────────────────────────────────────────
    function test_lock_revertsAmountZero() public {
        vm.prank(requester);
        vm.expectRevert(bytes("Amount must be > 0"));
        escrow.lockPayment(JOB, provider, 0);
    }

    function test_lock_revertsProviderZero() public {
        vm.prank(requester);
        vm.expectRevert(bytes("Invalid provider"));
        escrow.lockPayment(JOB, address(0), 1 ether);
    }

    function test_lock_revertsAlreadyEscrowed() public {
        _lock(10 ether);
        vm.prank(requester);
        vm.expectRevert(bytes("Job already escrowed"));
        escrow.lockPayment(JOB, provider, 10 ether);
    }

    function test_lock_revertsWhenPaused() public {
        escrow.pause();
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        escrow.lockPayment(JOB, provider, 10 ether);
    }

    // ─── releasePayment guards + branches ──────────────────────────────────
    function test_release_revertsNotCoordinator() public {
        _lock(10 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("Not coordinator"));
        escrow.releasePayment(JOB, bytes32(0));
    }

    function test_release_revertsNotFound() public {
        // never locked: status defaults to Locked(0) so the status check passes,
        // exercising the lockedAt==0 "Escrow not found" branch.
        vm.prank(coordinator);
        vm.expectRevert(bytes("Escrow not found"));
        escrow.releasePayment(keccak256("nope"), bytes32(0));
    }

    function test_release_revertsNotActive() public {
        _lock(10 ether);
        vm.prank(coordinator);
        escrow.releasePayment(JOB, bytes32(0));
        vm.prank(coordinator);
        vm.expectRevert(bytes("Escrow not active"));
        escrow.releasePayment(JOB, bytes32(0));
    }

    function test_release_ownerIsAuthorized() public {
        // onlyCoordinator also allows owner() — cover that OR branch.
        _lock(10 ether);
        escrow.releasePayment(JOB, keccak256("poc")); // owner = address(this)
        (, , , , , MyAIEscrow.EscrowStatus status, ) = escrow.escrows(JOB);
        assertEq(uint256(status), uint256(MyAIEscrow.EscrowStatus.Released));
    }

    function test_release_zeroFeeSkipsTreasuryTransfer() public {
        // feeBps=0 → feeAmount==0 → the `if (feeAmount > 0)` branch is false.
        escrow.setFeeBps(0);
        _lock(100 ether);
        uint256 tBefore = token.balanceOf(treasury);
        vm.prank(coordinator);
        escrow.releasePayment(JOB, keccak256("poc"));
        assertEq(token.balanceOf(treasury), tBefore, "no fee should be sent");
        // 20% burned, 80% to provider when fee is 0
        assertEq(token.balanceOf(provider), 80 ether);
    }

    // ─── refundPayment guards ──────────────────────────────────────────────
    function test_refund_revertsNotCoordinator() public {
        _lock(10 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("Not coordinator"));
        escrow.refundPayment(JOB);
    }

    function test_refund_revertsNotActive() public {
        _lock(10 ether);
        vm.prank(coordinator);
        escrow.refundPayment(JOB);
        vm.prank(coordinator);
        vm.expectRevert(bytes("Escrow not active"));
        escrow.refundPayment(JOB);
    }

    // ─── claimExpired guards ───────────────────────────────────────────────
    function test_claimExpired_revertsNotRequester() public {
        _lock(10 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(stranger);
        vm.expectRevert(bytes("Not requester"));
        escrow.claimExpired(JOB);
    }

    function test_claimExpired_revertsNotExpiredYet() public {
        _lock(10 ether);
        vm.prank(requester);
        vm.expectRevert(bytes("Not expired yet"));
        escrow.claimExpired(JOB);
    }

    function test_claimExpired_revertsNotActive() public {
        _lock(10 ether);
        vm.prank(coordinator);
        escrow.releasePayment(JOB, bytes32(0));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(requester);
        vm.expectRevert(bytes("Escrow not active"));
        escrow.claimExpired(JOB);
    }

    function test_claimExpired_succeedsAfterTimeout() public {
        _lock(10 ether);
        uint256 bal = token.balanceOf(requester);
        vm.warp(block.timestamp + escrow.escrowTimeout() + 1);
        vm.prank(requester);
        escrow.claimExpired(JOB);
        assertEq(token.balanceOf(requester), bal + 10 ether);
    }

    // ─── Admin guards ──────────────────────────────────────────────────────
    function test_setFeeBps_revertsExceedsCap() public {
        vm.expectRevert(bytes("Exceeds 10% cap"));
        escrow.setFeeBps(1001);
    }

    function test_setFeeBps_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        escrow.setFeeBps(100);
    }

    function test_setCoordinator_revertsZero() public {
        vm.expectRevert(bytes("Zero address"));
        escrow.setCoordinator(address(0));
    }

    function test_setCoordinator_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        escrow.setCoordinator(provider);
    }

    function test_setTreasury_revertsZero() public {
        vm.expectRevert(bytes("Zero address"));
        escrow.setTreasury(address(0));
    }

    function test_setTreasury_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        escrow.setTreasury(provider);
    }

    function test_setEscrowTimeout_revertsTooLow() public {
        vm.expectRevert(bytes("Timeout out of range"));
        escrow.setEscrowTimeout(4 minutes);
    }

    function test_setEscrowTimeout_revertsTooHigh() public {
        vm.expectRevert(bytes("Timeout out of range"));
        escrow.setEscrowTimeout(31 days);
    }

    function test_setEscrowTimeout_succeedsInRange() public {
        escrow.setEscrowTimeout(2 hours);
        assertEq(escrow.escrowTimeout(), 2 hours);
    }

    function test_pause_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        escrow.pause();
    }

    function test_unpause_revertsNotOwner() public {
        escrow.pause();
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        escrow.unpause();
    }

    function test_pauseUnpause_roundtrip() public {
        escrow.pause();
        escrow.unpause();
        _lock(5 ether); // works again after unpause
        (, , uint256 amount, , , , ) = escrow.escrows(JOB);
        assertEq(amount, 5 ether);
    }
}
