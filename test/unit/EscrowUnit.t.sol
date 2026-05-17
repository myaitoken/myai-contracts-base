// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIEscrow} from "../../contracts/MyAIEscrow.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract EscrowUnitTest is Test {
    MyAIEscrow public escrow;
    MockERC20 public token;
    address coordinator = address(0xC00);
    address requester   = address(0xA1);
    address provider    = address(0xB2);
    address treasury    = address(0xCAFE);

    bytes32 constant JOB = keccak256("job-1");

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        escrow = new MyAIEscrow(address(token), coordinator, treasury);
        token.transfer(requester, 100_000 ether);
        vm.prank(requester);
        token.approve(address(escrow), type(uint256).max);
    }

    function _lock(uint256 amount) internal {
        vm.prank(requester);
        escrow.lockPayment(JOB, provider, amount);
    }

    function test_E2_releaseTwiceReverts() public {
        _lock(100 ether);
        vm.prank(coordinator);
        escrow.releasePayment(JOB, keccak256("poc"));
        vm.prank(coordinator);
        vm.expectRevert(bytes("Escrow not active"));
        escrow.releasePayment(JOB, keccak256("poc"));
    }

    function test_E2_refundThenReleaseReverts() public {
        _lock(50 ether);
        vm.prank(coordinator);
        escrow.refundPayment(JOB);
        vm.prank(coordinator);
        vm.expectRevert(bytes("Escrow not active"));
        escrow.releasePayment(JOB, keccak256("poc"));
    }

    function test_E3_claimExpiredOnlyRequester() public {
        _lock(10 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Not requester"));
        escrow.claimExpired(JOB);
        uint256 beforeBal = token.balanceOf(requester);
        vm.prank(requester);
        escrow.claimExpired(JOB);
        assertEq(token.balanceOf(requester) - beforeBal, 10 ether);
    }

    function test_E4_expiredAlwaysSucceedsForPayer() public {
        _lock(7 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(requester);
        escrow.claimExpired(JOB);
    }

    function test_E4_preTimeoutReverts() public {
        _lock(1 ether);
        vm.prank(requester);
        vm.expectRevert(bytes("Not expired yet"));
        escrow.claimExpired(JOB);
    }

    function test_previewSplit() public view {
        (uint256 prov, uint256 burn, uint256 fee) = escrow.previewSplit(10_000);
        assertEq(burn, 2_000);
        assertEq(fee, 300);
        assertEq(prov, 10_000 - 2_000 - 300);
    }

    function test_setFeeBpsOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        escrow.setFeeBps(500);
        escrow.setFeeBps(500);
        assertEq(escrow.feeBps(), 500);
    }

    function test_setFeeBpsCap() public {
        vm.expectRevert(bytes("Exceeds 10% cap"));
        escrow.setFeeBps(1001);
    }

    function test_pauseBlocksLock() public {
        escrow.pause();
        vm.prank(requester);
        vm.expectRevert();
        escrow.lockPayment(JOB, provider, 1 ether);
        escrow.unpause();
        vm.prank(requester);
        escrow.lockPayment(JOB, provider, 1 ether);
    }

    function test_zeroChecks() public {
        vm.expectRevert(bytes("Token zero"));
        new MyAIEscrow(address(0), coordinator, treasury);
        vm.expectRevert(bytes("Coordinator zero"));
        new MyAIEscrow(address(token), address(0), treasury);
        vm.expectRevert(bytes("Treasury zero"));
        new MyAIEscrow(address(token), coordinator, address(0));
    }

    function testFuzz_releaseAccounting(uint96 amountSeed) public {
        // Use bound (not vm.assume) so the fuzzer never rejects -- avoids
        // "rejected too many inputs" failures past ~250k runs.
        uint256 amount = bound(uint256(amountSeed), 1, 50_000 ether);
        bytes32 j = keccak256(abi.encode(amount));
        vm.prank(requester);
        escrow.lockPayment(j, provider, amount);
        uint256 t0 = token.balanceOf(treasury);
        uint256 p0 = token.balanceOf(provider);
        uint256 b0 = token.balanceOf(address(0xdead));
        vm.prank(coordinator);
        escrow.releasePayment(j, keccak256("poc"));
        (uint256 prov, uint256 burn, uint256 fee) = escrow.previewSplit(amount);
        assertEq(token.balanceOf(provider) - p0, prov);
        assertEq(token.balanceOf(treasury) - t0, fee);
        assertEq(token.balanceOf(address(0xdead)) - b0, burn);
    }

    function test_releaseRejectsNonCoordinator() public {
        _lock(1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Not coordinator"));
        escrow.releasePayment(JOB, keccak256("p"));
    }

    function test_refundRejectsNonCoordinator() public {
        _lock(1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Not coordinator"));
        escrow.refundPayment(JOB);
    }

    function test_setCoordinatorZero() public {
        vm.expectRevert(bytes("Zero address"));
        escrow.setCoordinator(address(0));
    }

    function test_setTreasuryZero() public {
        vm.expectRevert(bytes("Zero address"));
        escrow.setTreasury(address(0));
    }

    function test_setTimeoutRange() public {
        vm.expectRevert(bytes("Timeout out of range"));
        escrow.setEscrowTimeout(1 minutes);
        vm.expectRevert(bytes("Timeout out of range"));
        escrow.setEscrowTimeout(31 days);
        escrow.setEscrowTimeout(1 days);
        assertEq(escrow.escrowTimeout(), 1 days);
    }

    function test_lockDuplicateReverts() public {
        _lock(1 ether);
        vm.prank(requester);
        vm.expectRevert(bytes("Job already escrowed"));
        escrow.lockPayment(JOB, provider, 1 ether);
    }

    function test_lockInvalidProvider() public {
        vm.prank(requester);
        vm.expectRevert(bytes("Invalid provider"));
        escrow.lockPayment(JOB, address(0), 1 ether);
    }

    function test_lockZeroAmount() public {
        vm.prank(requester);
        vm.expectRevert(bytes("Amount must be > 0"));
        escrow.lockPayment(JOB, provider, 0);
    }

    function test_coordinatorUpdate() public {
        escrow.setCoordinator(address(0x1234));
        assertEq(escrow.coordinator(), address(0x1234));
    }

    function test_treasuryUpdate() public {
        escrow.setTreasury(address(0x5678));
        assertEq(escrow.protocolTreasury(), address(0x5678));
    }

    function test_ownerCanReleaseToo() public {
        _lock(1 ether);
        // owner is `this` (deployer)
        escrow.releasePayment(JOB, keccak256("p"));
    }
}
