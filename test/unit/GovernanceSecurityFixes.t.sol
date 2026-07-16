// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIGovernance} from "../../contracts/MyAIGovernance.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @dev Regression tests for the pre-audit High-severity governance fixes:
///      #9686 (flash-stake takeover: vote weight must be snapshotted at proposal
///      creation) and #9687 (unbounded on-chain loop in propose() -> permanent DoS;
///      the quorum denominator must be read in O(1)).
contract GovernanceSecurityFixesTest is Test {
    MyAIGovernance public gov;
    MyAIReputation public rep;
    MockERC20 public token;

    address coordinator = address(0xC00);
    address honest = address(0xA1);
    address attacker = address(0xBAD);

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

    function _stake(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.startPrank(who);
        token.approve(address(rep), amount);
        rep.stake(amount);
        vm.stopPrank();
    }

    // ── #9686: weight acquired AFTER a proposal cannot vote ──────────────────
    function test_9686_flashStakeAfterProposalCannotVote() public {
        _giveGovPoints(honest, 150);
        vm.roll(block.number + 1);

        vm.prank(honest);
        uint256 id = gov.propose("t", "d", address(0), "");

        // A later block: attacker flash-stakes a huge amount AFTER proposal exists.
        vm.roll(block.number + 1);
        _stake(attacker, 10_000 ether);

        // Live weight is huge...
        assertEq(gov.getVotingWeight(attacker), 10_000, "live weight reflects stake");
        // ...but snapshot weight at the proposal block was zero -> vote is rejected.
        vm.prank(attacker);
        vm.expectRevert(bytes("No voting weight"));
        gov.vote(id, true);

        // The genuine holder-at-snapshot can still vote with its snapshot weight.
        vm.prank(honest);
        gov.vote(id, true);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.votesFor, 150, "holder-at-snapshot votes with pre-proposal weight");
    }

    // ── #9686: weight gained AFTER snapshot does not inflate an eligible vote ─
    function test_9686_weightIncreaseAfterSnapshotIgnored() public {
        _giveGovPoints(honest, 150);
        vm.roll(block.number + 1);
        vm.prank(honest);
        uint256 id = gov.propose("t", "d", address(0), "");

        // Same holder piles on stake after the snapshot.
        vm.roll(block.number + 1);
        _stake(honest, 1_000 ether); // live weight now 150 + 1000 = 1150

        assertEq(gov.getVotingWeight(honest), 1_150, "live weight inflated");
        vm.prank(honest);
        gov.vote(id, true);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.votesFor, 150, "vote counted at snapshot weight, not inflated live weight");
    }

    // ── #9686: stake placed BEFORE the snapshot legitimately counts ──────────
    function test_9686_stakeBeforeSnapshotCounts() public {
        _giveGovPoints(honest, 50);
        _stake(honest, 100 ether); // weight 50 + 100 = 150 before any proposal
        vm.roll(block.number + 1);

        vm.prank(honest);
        uint256 id = gov.propose("t", "d", address(0), "");
        vm.prank(honest);
        gov.vote(id, true);
        MyAIGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.votesFor, 150, "pre-snapshot stake+points count in full");
    }

    function _registerRange(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; i++) {
            address a = address(uint160(0x100000 + i));
            vm.prank(a);
            rep.register();
        }
    }

    function _measurePropose(string memory t) internal returns (uint256 used) {
        vm.prank(honest);
        uint256 g = gasleft();
        gov.propose(t, "d", address(0), "");
        used = g - gasleft();
    }

    // Diagnostic: log propose gas as the registered-agent set grows large.
    function test_9687_diag_gasCurve() public {
        _giveGovPoints(honest, 600);
        _measurePropose("warmup"); // burn proposalCount 0->1 asymmetry
        _registerRange(0, 500);
        emit log_named_uint("propose gas @ ~500 agents", _measurePropose("a"));
        _registerRange(500, 1500);
        emit log_named_uint("propose gas @ ~1500 agents", _measurePropose("b"));
        _registerRange(1500, 3000);
        emit log_named_uint("propose gas @ ~3000 agents", _measurePropose("c"));
    }

    // ── #9687: propose() gas is O(1) regardless of registered-agent count ────
    function test_9687_proposeGasDoesNotGrowWithAgentSet() public {
        _giveGovPoints(honest, 600); // enough weight to propose several times
        _measurePropose("warmup"); // normalize proposalCount SSTORE cost (0->1 vs 1->2)

        _registerRange(0, 50);
        uint256 usedSmall = _measurePropose("a");

        // Attacker mass-registers 3,000 agents: register() is free/permissionless.
        _registerRange(50, 3000);
        uint256 usedLarge = _measurePropose("b");

        emit log_named_uint("propose gas @ 51 agents", usedSmall);
        emit log_named_uint("propose gas @ 3001 agents", usedLarge);

        // True O(1): a 60x larger agent set changes propose() cost by at most a
        // few hundred gas. Under the old O(N) loop over registeredAgents this
        // ballooned into the millions and eventually exceeded the block gas limit,
        // permanently bricking propose() (audit #9687).
        assertApproxEqAbs(usedLarge, usedSmall, 1_000, "propose gas must not scale with agent count");
        assertLt(usedLarge, 400_000, "propose stays well under the block gas limit");
    }
}
