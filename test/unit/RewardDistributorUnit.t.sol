// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIRewardDistributor} from "../../contracts/MyAIRewardDistributor.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @notice Unit + branch tests for MyAIRewardDistributor (Merkle claim).
/// Builds a 2-leaf tree inline; OZ MerkleProof hashes pairs sorted.
contract RewardDistributorUnitTest is Test {
    MyAIRewardDistributor public dist;
    MockERC20 public token;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address stranger = address(0xBAD);

    uint256 constant A_AMT = 100 ether;
    uint256 constant B_AMT = 250 ether;
    uint256 deadline;

    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);

        leafA = keccak256(abi.encodePacked(uint256(0), alice, A_AMT));
        leafB = keccak256(abi.encodePacked(uint256(1), bob, B_AMT));
        root = leafA <= leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));

        deadline = block.timestamp + 30 days;
        dist = new MyAIRewardDistributor(address(token), root, deadline);
        token.transfer(address(dist), 1_000 ether);
    }

    function _proofA() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafB;
    }

    function _proofB() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafA;
    }

    // ─── Happy path ─────────────────────────────────────────────────────────
    function test_claimAlice() public {
        dist.claim(0, alice, A_AMT, _proofA());
        assertEq(token.balanceOf(alice), A_AMT);
        assertTrue(dist.isClaimed(0));
    }

    function test_claimBoth() public {
        dist.claim(0, alice, A_AMT, _proofA());
        dist.claim(1, bob, B_AMT, _proofB());
        assertEq(token.balanceOf(bob), B_AMT);
        assertTrue(dist.isClaimed(1));
    }

    // ─── Reverts ──────────────────────────────────────────────────────────────
    function test_doubleClaimReverts() public {
        dist.claim(0, alice, A_AMT, _proofA());
        vm.expectRevert(MyAIRewardDistributor.AlreadyClaimed.selector);
        dist.claim(0, alice, A_AMT, _proofA());
    }

    function test_invalidProofReverts_wrongAmount() public {
        vm.expectRevert(MyAIRewardDistributor.InvalidProof.selector);
        dist.claim(0, alice, A_AMT + 1, _proofA());
    }

    function test_invalidProofReverts_wrongAccount() public {
        vm.expectRevert(MyAIRewardDistributor.InvalidProof.selector);
        dist.claim(0, stranger, A_AMT, _proofA());
    }

    function test_claimAfterDeadlineReverts() public {
        vm.warp(deadline + 1);
        vm.expectRevert(MyAIRewardDistributor.ClaimWindowClosed.selector);
        dist.claim(0, alice, A_AMT, _proofA());
    }

    function test_ctor_revertsTokenZero() public {
        vm.expectRevert(bytes("Token zero"));
        new MyAIRewardDistributor(address(0), root, deadline);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────
    function test_setMerkleRoot_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        dist.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_setMerkleRoot_updates() public {
        dist.setMerkleRoot(bytes32(uint256(0xABC)));
        assertEq(dist.merkleRoot(), bytes32(uint256(0xABC)));
    }

    function test_sweep_revertsBeforeDeadline() public {
        vm.expectRevert(MyAIRewardDistributor.SweepNotAllowedYet.selector);
        dist.sweep(address(this));
    }

    function test_sweep_afterDeadline() public {
        // alice claims 100; 900 remains to sweep
        dist.claim(0, alice, A_AMT, _proofA());
        vm.warp(deadline + 1);
        dist.sweep(bob);
        assertEq(token.balanceOf(bob), 900 ether);
        assertEq(token.balanceOf(address(dist)), 0);
    }

    function test_sweep_onlyOwner() public {
        vm.warp(deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        dist.sweep(stranger);
    }
}
