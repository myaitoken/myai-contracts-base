// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIGovernance} from "../../contracts/MyAIGovernance.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @dev Branch-coverage supplement for MyAIGovernance: the paths the happy-path
/// unit suite leaves uncovered — QuorumNotMet, finalize/vote on a non-Active
/// proposal, and execute() with a real call target (success + failure).

/// Minimal call target for execute() coverage.
contract _GovTarget {
    uint256 public x;
    function setX(uint256 v) external { x = v; }
    function boom() external pure { revert("boom"); }
}

contract GovernanceBranchesTest is Test {
    MyAIGovernance public gov;
    MyAIReputation public rep;
    MockERC20 public token;
    address coordinator = address(0xC00);
    address voter1 = address(0xA1);
    address voter2 = address(0xA2);

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
        gov = new MyAIGovernance(address(rep));
    }

    function _giveGovPoints(address who, uint256 n) internal {
        vm.startPrank(coordinator);
        for (uint256 i = 0; i < n; i++) {
            rep.recordCompletion(who, true, 1000, 100);
        }
        vm.stopPrank();
    }

    function _proposeWith(address target, bytes memory cd) internal returns (uint256) {
        _giveGovPoints(voter1, 150);
        vm.prank(voter1);
        return gov.propose("title", "desc", target, cd);
    }

    // ── finalize: quorum not met (zero turnout → participation 0 < 10%) ─────
    function test_finalize_revertsQuorumNotMet() public {
        uint256 id = _proposeWith(address(0), "");
        vm.warp(block.timestamp + 4 days); // nobody voted -> participation 0 < quorum 1000
        vm.expectRevert(abi.encodeWithSelector(MyAIGovernance.QuorumNotMet.selector, uint256(0), uint256(1000)));
        gov.finalize(id);
    }

    // ── finalize: already finalized → "Not active" ──────────────────────────
    function test_finalize_revertsNotActive() public {
        uint256 id = _proposeWith(address(0), "");
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id); // -> Passed
        vm.expectRevert(bytes("Not active"));
        gov.finalize(id);
    }

    // ── vote: on a finalized (non-Active) proposal → "Proposal not active" ──
    function test_vote_revertsProposalNotActive() public {
        uint256 id = _proposeWith(address(0), "");
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id); // status -> Passed
        _giveGovPoints(voter2, 5);
        vm.prank(voter2);
        vm.expectRevert(bytes("Proposal not active"));
        gov.vote(id, true);
    }

    // ── execute: real call target succeeds (covers target!=0 && callData>0) ─
    function test_execute_realCallExecutes() public {
        _GovTarget tgt = new _GovTarget();
        bytes memory cd = abi.encodeWithSignature("setX(uint256)", uint256(42));
        uint256 start = block.timestamp;
        gov.setTargetAllowed(address(tgt), true);
        uint256 id = _proposeWith(address(tgt), cd);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(start + 3 days + 1);
        gov.finalize(id); // -> Passed
        vm.warp(start + 3 days + 48 hours + 1);
        gov.execute(id);
        assertEq(tgt.x(), 42);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Executed);
    }

    // ── execute: target call reverts → "Execution failed" ───────────────────
    function test_execute_revertsExecutionFailed() public {
        _GovTarget tgt = new _GovTarget();
        bytes memory cd = abi.encodeWithSignature("boom()");
        uint256 start = block.timestamp;
        gov.setTargetAllowed(address(tgt), true);
        uint256 id = _proposeWith(address(tgt), cd);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(start + 3 days + 1);
        gov.finalize(id);
        vm.warp(start + 3 days + 48 hours + 1);
        vm.expectRevert(bytes("Execution failed"));
        gov.execute(id);
    }

    // ── #9670: execute() to a NON-allowlisted target is blocked ──────────────────
    function test_9670_arbitraryCallBlockedWhenNotAllowlisted() public {
        _GovTarget tgt = new _GovTarget();
        bytes memory cd = abi.encodeWithSignature("setX(uint256)", uint256(42));
        uint256 start = block.timestamp;
        // NOTE: target deliberately NOT allowlisted.
        uint256 id = _proposeWith(address(tgt), cd);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(start + 3 days + 1);
        gov.finalize(id); // -> Passed
        vm.warp(start + 3 days + 48 hours + 1);
        vm.expectRevert(bytes("Target not allowlisted"));
        gov.execute(id);
        assertEq(tgt.x(), 0, "arbitrary call must not have executed");
    }

    // ── #9670: owner can revoke a target during the timelock to defuse a proposal ──
    function test_9670_ownerRevokeDuringTimelockBlocksExecution() public {
        _GovTarget tgt = new _GovTarget();
        bytes memory cd = abi.encodeWithSignature("setX(uint256)", uint256(42));
        uint256 start = block.timestamp;
        gov.setTargetAllowed(address(tgt), true);
        uint256 id = _proposeWith(address(tgt), cd);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(start + 3 days + 1);
        gov.finalize(id); // -> Passed
        // Owner spots the malicious proposal and revokes the target mid-timelock.
        gov.setTargetAllowed(address(tgt), false);
        vm.warp(start + 3 days + 48 hours + 1);
        vm.expectRevert(bytes("Target not allowlisted"));
        gov.execute(id);
    }

    // ── #9670: setTargetAllowed is owner-only and rejects the zero sentinel ─────
    function test_9670_setTargetAllowedOnlyOwner() public {
        _GovTarget tgt = new _GovTarget();
        vm.prank(voter1);
        vm.expectRevert();
        gov.setTargetAllowed(address(tgt), true);
    }

    function test_9670_setTargetAllowedRejectsZero() public {
        vm.expectRevert(bytes("Zero target"));
        gov.setTargetAllowed(address(0), true);
    }
}
