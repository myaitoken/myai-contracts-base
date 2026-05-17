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
}
