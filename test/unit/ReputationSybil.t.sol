// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @dev Audit #9700 — anti-sybil coverage for MyAIReputation.
///      Before: register() granted a FREE max score (10000), instantly clearing
///      the >=9000 vouch threshold, and vouch was permissionless (+100 each), so
///      reputation and getTopProviders were trivially sybil-inflatable.
///      After: new agents start at INITIAL_REPUTATION (0) and must EARN score via
///      coordinator-verified work; vouching now requires earned high reputation,
///      an at-risk stake, and is rate-limited.
///      These tests also assert the gov-branch voting-weight accounting
///      (totalVotingWeight / getPastVotingWeight) stays consistent under the new
///      initial-score behavior.
contract ReputationSybilTest is Test {
    MyAIReputation public rep;
    MockERC20 public token;
    address coordinator = address(0xC00);

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 10_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
    }

    function _fund(address who, uint256 amt) internal {
        token.transfer(who, amt);
        vm.prank(who);
        token.approve(address(rep), type(uint256).max);
    }

    function _makeLegitVoucher(address who) internal {
        vm.prank(coordinator);
        rep.recordCompletion(who, true, 100, 100); // earn ~9993
        uint256 need = rep.minVouchStake();
        _fund(who, need);
        vm.prank(who);
        rep.stake(need);
    }

    // ── free max score removed ───────────────────────────────────────────────

    function test_registerStartsAtZero() public {
        address a = address(0xA1);
        vm.prank(a);
        rep.register();
        assertEq(rep.getProfile(a).reputationScore, 0, "no free score on registration");
    }

    /// An attacker mass-registers identities; none get any score, so none surface
    /// in getTopProviders above a floor.
    function test_massRegistrationCannotInflateTopProviders() public {
        for (uint160 i = 1; i <= 25; i++) {
            address a = address(0x10000 + i);
            vm.prank(a);
            rep.register();
        }
        assertEq(rep.totalAgents(), 25);
        (address[] memory top,) = rep.getTopProviders(1, 50); // score >= 1
        for (uint i = 0; i < top.length; i++) {
            assertEq(top[i], address(0), "no sybil surfaces with any earned score");
        }
    }

    /// Reputation is EARNED: zero before verified work, high after.
    function test_reputationEarnedViaRecordCompletion() public {
        address a = address(0xA1);
        vm.prank(a);
        rep.register();
        assertEq(rep.getProfile(a).reputationScore, 0);

        vm.prank(coordinator);
        rep.recordCompletion(a, true, 100, 100); // fast verified success
        assertGe(rep.getProfile(a).reputationScore, 9000, "earns high score through work");
    }

    /// Auto-registration (first sight by the coordinator) also starts from zero;
    /// a single FAILED first job does not confer max score.
    function test_autoRegisterFailedJobIsNotMax() public {
        address a = address(0xA2);
        vm.prank(coordinator);
        rep.recordCompletion(a, false, 0, 0);
        assertLt(rep.getProfile(a).reputationScore, 9000, "failed first job is not max");
    }

    // ── vouch is no longer permissionless ────────────────────────────────────

    function test_freshAgentCannotVouch() public {
        address a = address(0xA1);
        address b = address(0xB1);
        vm.prank(a);
        rep.register(); // score 0
        vm.prank(b);
        rep.register();
        vm.prank(a);
        vm.expectRevert(bytes("Reputation too low to vouch"));
        rep.vouch(b);
    }

    function test_vouchRequiresStake() public {
        address a = address(0xA1);
        address b = address(0xB1);
        // a earns high rep but posts NO stake
        vm.prank(coordinator);
        rep.recordCompletion(a, true, 100, 100);
        assertGe(rep.getProfile(a).reputationScore, 9000);
        vm.prank(b);
        rep.register();
        vm.prank(a);
        vm.expectRevert(bytes("Insufficient stake to vouch"));
        rep.vouch(b);
    }

    function test_vouchIsRateLimited() public {
        address a = address(0xA1);
        address b = address(0xB1);
        address c = address(0xC1);
        _makeLegitVoucher(a);
        vm.prank(b);
        rep.register();
        vm.prank(c);
        rep.register();

        vm.prank(a);
        rep.vouch(b); // first vouch ok
        vm.prank(a);
        vm.expectRevert(bytes("Vouch cooldown active"));
        rep.vouch(c); // second vouch within cooldown blocked

        vm.warp(block.timestamp + rep.VOUCH_COOLDOWN() + 1);
        vm.prank(a);
        rep.vouch(c); // allowed after cooldown
        assertEq(rep.getProfile(c).reputationScore, 100);
    }

    /// A legitimate voucher (earned rep + stake) can still vouch — onboarding of
    /// real, verified agents is not broken by the hardening.
    function test_legitVouchStillWorks() public {
        address a = address(0xA1);
        address b = address(0xB1);
        _makeLegitVoucher(a);
        vm.prank(b);
        rep.register();
        vm.prank(a);
        rep.vouch(b);
        assertEq(rep.getProfile(b).reputationScore, 100);
        assertEq(rep.getProfile(b).vouchedBy.length, 1);
    }

    // ── gov-branch voting-weight accounting stays consistent ─────────────────

    /// register() must not move totalVotingWeight (weight = govPoints + staked,
    /// both zero for a fresh agent), regardless of the initial-score change.
    function test_registerDoesNotChangeTotalVotingWeight() public {
        assertEq(rep.totalVotingWeight(), 0);
        for (uint160 i = 1; i <= 10; i++) {
            address a = address(0x20000 + i);
            vm.prank(a);
            rep.register();
        }
        assertEq(rep.totalVotingWeight(), 0, "permissionless registration adds no voting weight");
    }

    /// Voting weight is earned exactly like reputation: through recorded work
    /// (governance points) and stake — the running total and the checkpoint agree.
    function test_totalVotingWeightTracksEarnedWeight() public {
        address a = address(0xA1);
        vm.roll(block.number + 1);
        vm.prank(coordinator);
        rep.recordCompletion(a, true, 100, 100); // +1 governance point => weight 1
        assertEq(rep.totalVotingWeight(), 1, "earned gov point counts once");

        _fund(a, 5 ether);
        vm.prank(a);
        rep.stake(5 ether); // +5 whole tokens => weight 6
        assertEq(rep.totalVotingWeight(), 6, "stake adds whole-token weight");

        vm.roll(block.number + 1);
        assertEq(rep.getPastVotingWeight(a, block.number), 6, "checkpoint agrees with running total");
    }
}
