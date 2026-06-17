// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @dev Branch-coverage supplement for MyAIReputation: constructor guards,
/// onlyCoordinator, register/stake/vouch reverts + edge branches, the slash
/// path, and setCoordinator guards.
contract ReputationBranchesTest is Test {
    MyAIReputation public rep;
    MockERC20 public token;
    address owner;                       // = address(this)
    address coordinator = address(0xC00);
    address a1 = address(0xA1);
    address a2 = address(0xA2);
    address stranger = address(0xBAD);

    function setUp() public {
        owner = address(this);
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
    }

    function _ownableErr(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", who);
    }

    function _fundApprove(address who, uint256 amt) internal {
        token.transfer(who, amt);
        vm.prank(who);
        token.approve(address(rep), type(uint256).max);
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    function test_ctor_revertsCoordinatorZero() public {
        vm.expectRevert(bytes("Coordinator zero"));
        new MyAIReputation(address(0), address(token));
    }

    function test_ctor_revertsTokenZero() public {
        vm.expectRevert(bytes("Token zero"));
        new MyAIReputation(coordinator, address(0));
    }

    // ── Access control ──────────────────────────────────────────────────────
    function test_record_revertsNotCoordinator() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Not coordinator"));
        rep.recordCompletion(a1, true, 1000, 100);
    }

    function test_record_ownerIsAuthorized() public {
        rep.recordCompletion(a1, true, 1000, 100); // owner allowed via onlyCoordinator OR
        MyAIReputation.AgentProfile memory p = rep.getProfile(a1);
        assertEq(p.totalJobs, 1);
    }

    // ── register ─────────────────────────────────────────────────────────────
    function test_register_revertsAlready() public {
        vm.prank(a1);
        rep.register();
        vm.prank(a1);
        vm.expectRevert(bytes("Already registered"));
        rep.register();
    }

    // ── stake ────────────────────────────────────────────────────────────────
    function test_stake_revertsZero() public {
        vm.prank(a1);
        vm.expectRevert(bytes("Amount must be > 0"));
        rep.stake(0);
    }

    function test_stake_boostCappedAndScoreCapped() public {
        vm.prank(a1);
        rep.register(); // score 10000
        _fundApprove(a1, 1_000 ether);
        vm.prank(a1);
        rep.stake(1_000 ether); // boost = 1000*10 = 10000 -> capped 500; 10000+500 -> capped 10000
        MyAIReputation.AgentProfile memory p = rep.getProfile(a1);
        assertEq(p.reputationScore, 10000);
        assertEq(p.stakedAmount, 1_000 ether);
    }

    function test_stake_smallBoostBelowCap() public {
        // One failed job drops score to 2000, so a small boost stays under 10000.
        vm.prank(coordinator);
        rep.recordCompletion(a1, false, 0, 0); // score -> 2000
        _fundApprove(a1, 5 ether);
        vm.prank(a1);
        rep.stake(5 ether); // boost = 5*10 = 50 (not capped); 2000+50 = 2050 (< 10000)
        MyAIReputation.AgentProfile memory p = rep.getProfile(a1);
        assertEq(p.reputationScore, 2050);
    }

    // ── vouch ────────────────────────────────────────────────────────────────
    function test_vouch_revertsLowReputation() public {
        vm.prank(a1); // unregistered -> score 0 < 9000
        vm.expectRevert(bytes("Reputation too low to vouch"));
        rep.vouch(a2);
    }

    function test_vouch_revertsSelf() public {
        vm.prank(a1);
        rep.register(); // 10000 >= 9000
        vm.prank(a1);
        vm.expectRevert(bytes("Cannot vouch for self"));
        rep.vouch(a1);
    }

    function test_vouch_revertsAlready() public {
        vm.prank(a1);
        rep.register();
        vm.prank(a2);
        rep.register();
        vm.prank(a1);
        rep.vouch(a2);
        vm.prank(a1);
        vm.expectRevert(bytes("Already vouched"));
        rep.vouch(a2);
    }

    function test_vouch_succeedsBumpsScore() public {
        vm.prank(a1);
        rep.register();
        vm.prank(a2);
        rep.register(); // a2 score 10000 -> >= 9900 so NO bump branch
        // Use a fresh low-score vouchee to exercise the (< 9900) bump branch:
        vm.prank(coordinator);
        rep.recordCompletion(stranger, false, 0, 0); // stranger score 2000 (< 9900)
        vm.prank(a1);
        rep.vouch(stranger);
        MyAIReputation.AgentProfile memory p = rep.getProfile(stranger);
        assertEq(p.reputationScore, 2100); // +100
        assertEq(p.vouchedBy.length, 1);
    }

    // ── slashing (3 consecutive failures) ───────────────────────────────────
    function test_slash_afterThreeFailures() public {
        vm.startPrank(coordinator);
        rep.recordCompletion(a1, false, 0, 0);
        rep.recordCompletion(a1, false, 0, 0);
        rep.recordCompletion(a1, false, 0, 0); // 3rd -> slashed
        vm.stopPrank();
        MyAIReputation.AgentProfile memory p = rep.getProfile(a1);
        assertTrue(p.isSlashed);
        assertEq(p.consecutiveFailures, 3);
        assertGt(p.slashCooldownUntil, block.timestamp);
    }

    function test_slash_resetsAfterCooldownOnSuccess() public {
        vm.startPrank(coordinator);
        rep.recordCompletion(a1, false, 0, 0);
        rep.recordCompletion(a1, false, 0, 0);
        rep.recordCompletion(a1, false, 0, 0); // slashed
        vm.stopPrank();
        assertTrue(rep.getProfile(a1).isSlashed);
        vm.warp(block.timestamp + 49 hours); // past cooldown
        vm.prank(coordinator);
        rep.recordCompletion(a1, true, 1000, 100); // success past cooldown -> un-slash
        assertFalse(rep.getProfile(a1).isSlashed);
    }

    // ── setCoordinator ───────────────────────────────────────────────────────
    function test_setCoordinator_revertsZero() public {
        vm.expectRevert(bytes("Zero address"));
        rep.setCoordinator(address(0));
    }

    function test_setCoordinator_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(_ownableErr(stranger));
        rep.setCoordinator(a2);
    }

    function test_setCoordinator_succeeds() public {
        rep.setCoordinator(a2);
        assertEq(rep.coordinator(), a2);
    }
}
