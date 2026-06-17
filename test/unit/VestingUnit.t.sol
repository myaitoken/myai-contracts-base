// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIVesting} from "../../contracts/MyAIVesting.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @notice Unit tests for MyAIVesting (OZ VestingWallet wrapper, linear vest).
contract VestingUnitTest is Test {
    MyAIVesting public vest;
    MockERC20 public token;
    address beneficiary = address(0xBEEF);

    uint64 start;
    uint64 constant DURATION = 365 days;
    uint256 constant ALLOC = 1_000 ether;

    function setUp() public {
        token = new MockERC20("MyAI", "MYAI", 1_000_000 ether);
        start = uint64(block.timestamp);
        vest = new MyAIVesting(beneficiary, start, DURATION);
        token.transfer(address(vest), ALLOC);
    }

    function test_ownerIsBeneficiary() public view {
        assertEq(vest.owner(), beneficiary);
        assertEq(vest.start(), start);
        assertEq(vest.duration(), DURATION);
        assertEq(vest.end(), start + DURATION);
    }

    function test_nothingVestedAtStart() public view {
        assertEq(vest.releasable(address(token)), 0);
    }

    function test_halfVestedAtMidpoint() public {
        vm.warp(start + DURATION / 2);
        // linear: ~50% of allocation
        assertApproxEqAbs(vest.releasable(address(token)), ALLOC / 2, 1e15);
    }

    function test_fullyVestedAfterEnd() public {
        vm.warp(start + DURATION + 1);
        assertEq(vest.releasable(address(token)), ALLOC);
    }

    function test_releaseTransfersToBeneficiary() public {
        vm.warp(start + DURATION + 1);
        vest.release(address(token)); // anyone can trigger; funds go to beneficiary
        assertEq(token.balanceOf(beneficiary), ALLOC);
        assertEq(vest.released(address(token)), ALLOC);
        assertEq(vest.releasable(address(token)), 0);
    }

    function test_partialReleaseThenRemainder() public {
        vm.warp(start + DURATION / 2);
        vest.release(address(token));
        uint256 firstHalf = token.balanceOf(beneficiary);
        assertApproxEqAbs(firstHalf, ALLOC / 2, 1e15);
        vm.warp(start + DURATION + 1);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), ALLOC);
    }

    function testFuzz_vestedMonotonic(uint256 t) public {
        t = bound(t, 0, DURATION);
        vm.warp(start + t);
        uint256 vested = vest.vestedAmount(address(token), uint64(block.timestamp));
        assertLe(vested, ALLOC);
        assertEq(vested, (ALLOC * t) / DURATION);
    }
}
