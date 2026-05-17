// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract ReputationUnitTest is Test {
    MyAIReputation public rep;
    MockERC20 public token;
    address coordinator = address(0xC00);
    address provider    = address(0xA1);

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
        token.transfer(provider, 100_000 ether);
        vm.prank(provider);
        token.approve(address(rep), type(uint256).max);
    }

    function test_register() public {
        vm.prank(provider);
        rep.register();
        assertEq(rep.getProfile(provider).reputationScore, 10_000);
    }

    function test_registerTwiceReverts() public {
        vm.prank(provider);
        rep.register();
        vm.prank(provider);
        vm.expectRevert(bytes("Already registered"));
        rep.register();
    }

    function test_recordCompletionAutoRegisters() public {
        vm.prank(coordinator);
        rep.recordCompletion(provider, true, 1000, 100);
        assertEq(rep.getProfile(provider).successfulJobs, 1);
        assertEq(rep.getProfile(provider).totalJobs, 1);
    }

    function test_recordCompletionOnlyCoordinator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Not coordinator"));
        rep.recordCompletion(provider, true, 1000, 100);
    }

    function test_slashAfterThreshold() public {
        vm.startPrank(coordinator);
        rep.recordCompletion(provider, false, 0, 0);
        rep.recordCompletion(provider, false, 0, 0);
        assertFalse(rep.getProfile(provider).isSlashed);
        rep.recordCompletion(provider, false, 0, 0);
        assertTrue(rep.getProfile(provider).isSlashed);
        vm.stopPrank();
    }

    function test_stakeRequiresAmount() public {
        vm.prank(provider);
        vm.expectRevert(bytes("Amount must be > 0"));
        rep.stake(0);
    }

    function test_stakeIncreasesScore() public {
        vm.prank(provider);
        rep.register();
        uint256 pre = rep.getProfile(provider).reputationScore;
        vm.prank(provider);
        rep.stake(5 ether);
        assertGe(rep.getProfile(provider).reputationScore, pre);
        assertEq(rep.getProfile(provider).stakedAmount, 5 ether);
    }

    function test_vouchRequiresHighRep() public {
        vm.prank(provider);
        rep.register();
        address low = address(0xDD);
        vm.prank(low);
        vm.expectRevert(bytes("Reputation too low to vouch"));
        rep.vouch(provider);
    }

    function test_vouchNotSelf() public {
        vm.prank(provider);
        rep.register();
        vm.prank(provider);
        vm.expectRevert(bytes("Cannot vouch for self"));
        rep.vouch(provider);
    }

    function test_vouchHappyPath() public {
        vm.prank(provider);
        rep.register();
        address other = address(0xEE);
        vm.prank(other);
        rep.register();
        vm.prank(provider);
        rep.vouch(other);
        // other was 10000, no change because already maxed
        assertEq(rep.getProfile(other).reputationScore, 10_000);
    }

    function test_vouchTwiceReverts() public {
        vm.prank(provider);
        rep.register();
        address other = address(0xEE);
        vm.prank(other);
        rep.register();
        vm.prank(provider);
        rep.vouch(other);
        vm.prank(provider);
        vm.expectRevert(bytes("Already vouched"));
        rep.vouch(other);
    }

    function test_topProvidersFilters() public {
        vm.prank(provider);
        rep.register();
        address mid = address(0xEE);
        vm.prank(mid);
        rep.register();
        vm.startPrank(coordinator);
        rep.recordCompletion(mid, false, 0, 0);
        rep.recordCompletion(mid, false, 0, 0);
        rep.recordCompletion(mid, false, 0, 0);
        vm.stopPrank();
        (address[] memory top,) = rep.getTopProviders(9000, 10);
        bool foundMid;
        for (uint i = 0; i < top.length; i++) if (top[i] == mid) foundMid = true;
        assertFalse(foundMid);
    }

    function test_setCoordinator() public {
        vm.expectRevert(bytes("Zero address"));
        rep.setCoordinator(address(0));
        rep.setCoordinator(address(0x42));
        assertEq(rep.coordinator(), address(0x42));
    }

    function test_constructorZeroChecks() public {
        vm.expectRevert(bytes("Coordinator zero"));
        new MyAIReputation(address(0), address(token));
        vm.expectRevert(bytes("Token zero"));
        new MyAIReputation(coordinator, address(0));
    }

    function test_totalAgents() public {
        vm.prank(provider);
        rep.register();
        assertEq(rep.totalAgents(), 1);
    }

    function test_R5_runningAvgMatchesManual() public {
        uint256[5] memory latencies = [uint256(500), 1000, 1500, 2000, 2500];
        uint256 expected;
        vm.startPrank(coordinator);
        for (uint i = 0; i < 5; i++) {
            uint256 totalBefore = i;
            rep.recordCompletion(provider, true, latencies[i], 0);
            expected = (expected * totalBefore + latencies[i]) / (totalBefore + 1);
            assertEq(rep.getProfile(provider).avgLatencyMs, expected, "INV-R5");
        }
        vm.stopPrank();
    }

    function test_govPointsAccrue() public {
        vm.startPrank(coordinator);
        for (uint i = 0; i < 5; i++) {
            rep.recordCompletion(provider, true, 1000, 100);
        }
        vm.stopPrank();
        assertEq(rep.getProfile(provider).governancePoints, 5);
    }

    function test_consecutiveFailuresResetOnSuccess() public {
        vm.startPrank(coordinator);
        rep.recordCompletion(provider, false, 0, 0);
        rep.recordCompletion(provider, false, 0, 0);
        rep.recordCompletion(provider, true, 1000, 0);
        vm.stopPrank();
        assertEq(rep.getProfile(provider).consecutiveFailures, 0);
    }
}
