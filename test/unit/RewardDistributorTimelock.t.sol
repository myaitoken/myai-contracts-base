// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIRewardDistributor} from "../../contracts/MyAIRewardDistributor.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @notice Audit #9709 (PRE-AUDIT, not deployed on-chain): Merkle-root changes
///         must go through a propose -> ROOT_UPDATE_DELAY -> apply timelock.
contract RewardDistributorTimelockTest is Test {
    MyAIRewardDistributor public dist;
    MockERC20 public token;

    address stranger = address(0xBAD);

    bytes32 constant GENESIS = bytes32(uint256(0x1111));
    bytes32 constant NEWROOT = bytes32(uint256(0x2222));

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        dist  = new MyAIRewardDistributor(address(token), GENESIS, block.timestamp + 30 days);
    }

    function test_noInstantSetMerkleRoot() public view {
        assertEq(dist.merkleRoot(), GENESIS);
    }

    function test_propose_setsPendingButNotLive() public {
        dist.proposeMerkleRoot(NEWROOT);
        assertEq(dist.pendingMerkleRoot(), NEWROOT);
        assertEq(dist.pendingRootEta(), block.timestamp + dist.ROOT_UPDATE_DELAY());
        assertEq(dist.merkleRoot(), GENESIS);
    }

    function test_apply_revertsBeforeDelay() public {
        dist.proposeMerkleRoot(NEWROOT);
        vm.warp(block.timestamp + dist.ROOT_UPDATE_DELAY() - 1);
        vm.expectRevert(MyAIRewardDistributor.RootTimelockNotElapsed.selector);
        dist.applyMerkleRoot();
        assertEq(dist.merkleRoot(), GENESIS);
    }

    function test_apply_succeedsAfterDelay() public {
        dist.proposeMerkleRoot(NEWROOT);
        vm.warp(block.timestamp + dist.ROOT_UPDATE_DELAY());
        dist.applyMerkleRoot();
        assertEq(dist.merkleRoot(), NEWROOT);
        assertEq(dist.pendingRootEta(), 0);
        assertEq(dist.pendingMerkleRoot(), bytes32(0));
    }

    function test_apply_revertsWhenNothingPending() public {
        vm.expectRevert(MyAIRewardDistributor.NoPendingRootUpdate.selector);
        dist.applyMerkleRoot();
    }

    function test_cancel_clearsPending() public {
        dist.proposeMerkleRoot(NEWROOT);
        dist.cancelMerkleRootUpdate();
        assertEq(dist.pendingRootEta(), 0);
        assertEq(dist.pendingMerkleRoot(), bytes32(0));
        vm.warp(block.timestamp + dist.ROOT_UPDATE_DELAY() + 1);
        vm.expectRevert(MyAIRewardDistributor.NoPendingRootUpdate.selector);
        dist.applyMerkleRoot();
        assertEq(dist.merkleRoot(), GENESIS);
    }

    function test_reproposeRestartsDelay() public {
        dist.proposeMerkleRoot(NEWROOT);
        vm.warp(block.timestamp + 1 days);
        bytes32 other = bytes32(uint256(0x3333));
        dist.proposeMerkleRoot(other);
        assertEq(dist.pendingRootEta(), block.timestamp + dist.ROOT_UPDATE_DELAY());
        vm.warp(block.timestamp + dist.ROOT_UPDATE_DELAY() - 1);
        vm.expectRevert(MyAIRewardDistributor.RootTimelockNotElapsed.selector);
        dist.applyMerkleRoot();
    }

    function test_propose_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        dist.proposeMerkleRoot(NEWROOT);
    }

    function test_apply_onlyOwner() public {
        dist.proposeMerkleRoot(NEWROOT);
        vm.warp(block.timestamp + dist.ROOT_UPDATE_DELAY());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        dist.applyMerkleRoot();
    }

    function test_cancel_onlyOwner() public {
        dist.proposeMerkleRoot(NEWROOT);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        dist.cancelMerkleRootUpdate();
    }
}
