// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MyAIEscrow} from "../../../contracts/MyAIEscrow.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";

contract EscrowHandler is CommonBase, StdCheats, StdUtils {
    MyAIEscrow public escrow;
    MockERC20 public token;
    address public coordinator;
    address[] public actors;

    uint256 public totalLocked;
    uint256 public totalReleased;
    uint256 public totalRefunded;
    uint256 public totalExpired;

    bytes32[] public openJobs;
    bytes32[] public allJobs;
    mapping(bytes32 => address) public jobRequester;
    mapping(bytes32 => bool) public jobSettled;

    constructor(MyAIEscrow _escrow, MockERC20 _token, address _coordinator, address[] memory _actors) {
        escrow = _escrow;
        token = _token;
        coordinator = _coordinator;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function lockPayment(uint256 actorSeed, uint256 providerSeed, uint256 amount, uint256 jobSalt) external {
        address requester = _actor(actorSeed);
        address provider = _actor(providerSeed);
        if (provider == address(0)) return;
        amount = bound(amount, 1, 1_000 ether);
        if (token.balanceOf(requester) < amount) {
            deal(address(token), requester, token.balanceOf(requester) + amount);
        }
        bytes32 jobId = keccak256(abi.encodePacked(jobSalt, allJobs.length, requester));
        (, , , , uint256 lockedAt, , ) = escrow.escrows(jobId);
        if (lockedAt != 0) return;
        vm.startPrank(requester);
        token.approve(address(escrow), amount);
        try escrow.lockPayment(jobId, provider, amount) {
            totalLocked += amount;
            openJobs.push(jobId);
            allJobs.push(jobId);
            jobRequester[jobId] = requester;
        } catch {}
        vm.stopPrank();
    }

    function releasePayment(uint256 jobSeed) external {
        if (openJobs.length == 0) return;
        uint256 idx = bound(jobSeed, 0, openJobs.length - 1);
        bytes32 jobId = openJobs[idx];
        if (jobSettled[jobId]) { _removeOpen(idx); return; }
        (, , uint256 amount, , uint256 lockedAt, MyAIEscrow.EscrowStatus status, ) = escrow.escrows(jobId);
        if (lockedAt == 0 || status != MyAIEscrow.EscrowStatus.Locked) { _removeOpen(idx); return; }
        vm.prank(coordinator);
        try escrow.releasePayment(jobId, keccak256("poc")) {
            totalReleased += amount;
            jobSettled[jobId] = true;
            _removeOpen(idx);
        } catch {}
    }

    function refundPayment(uint256 jobSeed) external {
        if (openJobs.length == 0) return;
        uint256 idx = bound(jobSeed, 0, openJobs.length - 1);
        bytes32 jobId = openJobs[idx];
        if (jobSettled[jobId]) { _removeOpen(idx); return; }
        (, , uint256 amount, , uint256 lockedAt, MyAIEscrow.EscrowStatus status, ) = escrow.escrows(jobId);
        if (lockedAt == 0 || status != MyAIEscrow.EscrowStatus.Locked) { _removeOpen(idx); return; }
        vm.prank(coordinator);
        try escrow.refundPayment(jobId) {
            totalRefunded += amount;
            jobSettled[jobId] = true;
            _removeOpen(idx);
        } catch {}
    }

    function claimExpired(uint256 jobSeed, uint256 skipSeconds) external {
        if (openJobs.length == 0) return;
        uint256 idx = bound(jobSeed, 0, openJobs.length - 1);
        bytes32 jobId = openJobs[idx];
        if (jobSettled[jobId]) { _removeOpen(idx); return; }
        (address requester, , uint256 amount, , uint256 lockedAt, MyAIEscrow.EscrowStatus status, ) = escrow.escrows(jobId);
        if (lockedAt == 0 || status != MyAIEscrow.EscrowStatus.Locked) { _removeOpen(idx); return; }
        uint256 minSkip = (lockedAt + escrow.escrowTimeout() + 1) > block.timestamp
            ? (lockedAt + escrow.escrowTimeout() + 1) - block.timestamp
            : 1;
        uint256 jump = bound(skipSeconds, minSkip, minSkip + 7 days);
        vm.warp(block.timestamp + jump);
        vm.prank(requester);
        try escrow.claimExpired(jobId) {
            totalExpired += amount;
            jobSettled[jobId] = true;
            _removeOpen(idx);
        } catch {}
    }

    function _removeOpen(uint256 idx) internal {
        uint256 last = openJobs.length - 1;
        if (idx != last) openJobs[idx] = openJobs[last];
        openJobs.pop();
    }

    function jobsCount() external view returns (uint256) { return allJobs.length; }
    function openJobsCount() external view returns (uint256) { return openJobs.length; }
}
