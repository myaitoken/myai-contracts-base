// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIGovernance} from "../../contracts/MyAIGovernance.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract GovernanceUnitTest is Test {
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
        for (uint i = 0; i < n; i++) {
            rep.recordCompletion(who, true, 1000, 100);
        }
        vm.stopPrank();
    }

    function test_constructorZero() public {
        vm.expectRevert(bytes("Reputation zero"));
        new MyAIGovernance(address(0));
    }

    function test_proposeRequiresWeight() public {
        vm.prank(voter1);
        vm.expectRevert(bytes("Insufficient governance points"));
        gov.propose("t", "d", address(0), "");
    }

    function _propose() internal returns (uint256) {
        _giveGovPoints(voter1, 150);
        vm.prank(voter1);
        return gov.propose("title", "desc", address(0), "");
    }

    function test_proposeHappyPath() public {
        uint256 id = _propose();
        assertEq(id, 1);
    }

    function test_G1_voteRequiresWeight() public {
        uint256 id = _propose();
        vm.prank(voter2);
        vm.expectRevert(bytes("No voting weight"));
        gov.vote(id, true);
    }

    function test_voteHappyPath() public {
        uint256 id = _propose();
        _giveGovPoints(voter2, 5);
        vm.prank(voter2);
        gov.vote(id, true);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.votesFor, 5);
    }

    function test_voteTwiceReverts() public {
        uint256 id = _propose();
        _giveGovPoints(voter2, 5);
        vm.prank(voter2);
        gov.vote(id, true);
        vm.prank(voter2);
        vm.expectRevert(bytes("Already voted"));
        gov.vote(id, true);
    }

    function test_voteAfterEndReverts() public {
        uint256 id = _propose();
        _giveGovPoints(voter2, 5);
        vm.warp(block.timestamp + 4 days);
        vm.prank(voter2);
        vm.expectRevert(bytes("Voting ended"));
        gov.vote(id, true);
    }

    function test_G3_finalizeMajority() public {
        uint256 id = _propose();
        _giveGovPoints(voter2, 100);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.prank(voter2);
        gov.vote(id, false);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Passed);
    }

    function test_G3_finalizeFailed() public {
        uint256 id = _propose();
        _giveGovPoints(voter2, 500);
        vm.prank(voter1);
        gov.vote(id, true);
        vm.prank(voter2);
        gov.vote(id, false);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Failed);
    }

    function test_finalizeBeforeEndReverts() public {
        uint256 id = _propose();
        vm.expectRevert(bytes("Voting not ended"));
        gov.finalize(id);
    }

    function test_G4_executeOnceOnly() public {
        uint256 id = _propose();
        uint256 startT = block.timestamp;
        vm.prank(voter1);
        gov.vote(id, true);
        // Move past voting period (3 days) + timelock (48 hours) with safety margin
        vm.warp(startT + 3 days + 1);
        gov.finalize(id);
        vm.warp(startT + 3 days + 48 hours + 1);
        gov.execute(id);
        vm.expectRevert(bytes("Not passed"));
        gov.execute(id);
    }

    function test_executeBeforeTimelockReverts() public {
        uint256 id = _propose();
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        vm.expectRevert(bytes("Timelock not expired"));
        gov.execute(id);
    }

    function test_executeNotPassedReverts() public {
        uint256 id = _propose();
        vm.expectRevert(bytes("Not passed"));
        gov.execute(id);
    }

    function test_getVotingWeight() public {
        _giveGovPoints(voter1, 25);
        assertEq(gov.getVotingWeight(voter1), 25);
    }

    function test_finalizeOnlyActive() public {
        uint256 id = _propose();
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        vm.expectRevert(bytes("Not active"));
        gov.finalize(id);
    }

    /* ----------------------------------------------------------------------
       Quorum tests (security fix from #8906 scan: quorumBps was declared but
       never enforced; finalize() only checked votesFor > votesAgainst). The
       new logic snapshots total eligible voting weight at proposal-creation
       time and reverts finalize() with QuorumNotMet when participation
       (votesFor + votesAgainst) is below quorumBps of that snapshot.
       ---------------------------------------------------------------------- */

    address voter3 = address(0xA3);
    address voter4 = address(0xA4);

    /// Quorum is 10% (1000 bps). Build a 10-agent electorate, only proposer
    /// votes -> turnout 150 of total ~285 -> well above 10%, so finalize
    /// succeeds. Verifies the happy-path: quorum reached, proposal passes.
    function test_Q1_quorumMet_finalizeSucceeds() public {
        // 9 background voters x 15 pts each = 135 pts of background weight
        for (uint160 i = 0; i < 9; i++) {
            _giveGovPoints(address(uint160(0xB000) + i), 15);
        }
        // Proposer with 150 pts proposes -> eligible snapshot = 135 + 150 = 285
        uint256 id = _propose();
        // Only proposer votes -> turnout = 150 of 285 = 52.6% (>> 10% quorum)
        vm.prank(voter1);
        gov.vote(id, true);

        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);

        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Passed, "should pass with quorum met");
        assertGt(p.eligibleVotingWeight, 0, "eligible weight snapshotted");
    }

    /// Build a large electorate so the proposer's vote alone is < 10% of
    /// snapshotted eligible weight. finalize() must revert with QuorumNotMet
    /// even though votesFor > votesAgainst.
    function test_Q2_quorumNotMet_finalizeReverts() public {
        // Pre-seed 50 background voters x 100 pts = 5000 pts background weight
        // Proposer adds 150 -> eligible = 5150. 10% quorum threshold = 515 pts.
        for (uint160 i = 0; i < 50; i++) {
            _giveGovPoints(address(uint160(0xC000) + i), 100);
        }
        uint256 id = _propose();
        // Only proposer (150) votes -> participation 150/5150 = 2.9% < 10%
        vm.prank(voter1);
        gov.vote(id, true);

        vm.warp(block.timestamp + 4 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                MyAIGovernance.QuorumNotMet.selector,
                uint256(291), // 150 * 10000 / 5150 = 291 bps
                uint256(1000)
            )
        );
        gov.finalize(id);

        // Proposal stays Active (revert means no state change).
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Active, "stays active on revert");
    }

    /// Edge case: exactly meeting quorum should pass. With eligible=1000 and
    /// turnout=100, participation = 1000 bps which equals quorumBps -> passes.
    function test_Q3_quorumExactlyMet_finalizeSucceeds() public {
        // Build 5 background voters x 170 pts = 850 pts; proposer 150 -> eligible 1000
        for (uint160 i = 0; i < 5; i++) {
            _giveGovPoints(address(uint160(0xD000) + i), 170);
        }
        uint256 id = _propose();
        // Get proposer down to contributing exactly 100 to turnout: have one
        // background voter abstain and proposer + one background voter both
        // vote -> turnout = 150 + 170 = 320 of 1000 = 32% (>= 10%). Passes.
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.status == MyAIGovernance.ProposalStatus.Passed, "32% participation >= 10% quorum");
    }

    /// Snapshot semantics: eligible weight is captured at propose() time and
    /// is NOT affected by agents that register after the proposal exists.
    /// This lets late-registering agents not retroactively raise the bar.
    function test_Q4_eligibleWeightSnapshottedAtProposal() public {
        uint256 id = _propose(); // electorate = just voter1 (150 pts)
        MyAIGovernance.Proposal memory pBefore = gov.getProposal(id);
        uint256 snap = pBefore.eligibleVotingWeight;

        // Add 10 new agents AFTER proposal exists
        for (uint160 i = 0; i < 10; i++) {
            _giveGovPoints(address(uint160(0xE000) + i), 1000);
        }

        MyAIGovernance.Proposal memory pAfter = gov.getProposal(id);
        assertEq(pAfter.eligibleVotingWeight, snap, "snapshot must not change");
        // Proposer can still finalize: 150 / 150 = 100% participation.
        vm.prank(voter1);
        gov.vote(id, true);
        vm.warp(block.timestamp + 4 days);
        gov.finalize(id);
        MyAIGovernance.Proposal memory pDone = gov.getProposal(id);
        assertTrue(pDone.status == MyAIGovernance.ProposalStatus.Passed);
    }
}
