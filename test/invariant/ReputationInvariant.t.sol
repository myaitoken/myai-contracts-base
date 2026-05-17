// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ReputationHandler} from "./handlers/ReputationHandler.sol";

contract ReputationInvariantTest is Test {
    MyAIReputation public rep;
    MockERC20 public token;
    ReputationHandler public handler;

    address public owner = address(0xA11CE);
    address public coordinator = address(0xC00D);

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20("MyAI", "MYAI", 10_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
        vm.stopPrank();

        address[] memory actors = new address[](5);
        for (uint160 i = 0; i < 5; i++) {
            actors[i] = address(uint160(0x2000) + i);
            deal(address(token), actors[i], 10_000 ether);
        }
        handler = new ReputationHandler(rep, token, coordinator, actors);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = handler.register.selector;
        sels[1] = handler.recordCompletion.selector;
        sels[2] = handler.stake.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_R1_totalStakeMatchesSum() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint i = 0; i < n; i++) {
            address a = handler.touched(i);
            sum += rep.getProfile(a).stakedAmount;
        }
        assertEq(sum, handler.ghostTotalStaked(), "INV-R1");
    }

    function invariant_R2_stakeBalanceCovered() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint i = 0; i < n; i++) {
            address a = handler.touched(i);
            sum += rep.getProfile(a).stakedAmount;
        }
        assertLe(sum, token.balanceOf(address(rep)), "INV-R2");
    }

    function invariant_R4_scoreBounded() public view {
        uint256 n = handler.touchedCount();
        for (uint i = 0; i < n; i++) {
            address a = handler.touched(i);
            uint256 s = rep.getProfile(a).reputationScore;
            assertLe(s, 10_000, "INV-R4");
        }
    }

    function invariant_R5_avgLatencyBounded() public view {
        uint256 n = handler.touchedCount();
        for (uint i = 0; i < n; i++) {
            address a = handler.touched(i);
            if (handler.ghostSuccessJobs(a) == 0) continue;
            uint256 avg = rep.getProfile(a).avgLatencyMs;
            assertLe(avg, 60_000, "INV-R5");
        }
    }
}
