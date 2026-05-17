// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIEscrow} from "../../contracts/MyAIEscrow.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

contract EscrowInvariantTest is Test {
    MyAIEscrow public escrow;
    MockERC20 public token;
    EscrowHandler public handler;

    address public owner       = address(0xA11CE);
    address public coordinator = address(0xC00D);
    address public treasury    = address(0xBEEF);

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20("MyAI", "MYAI", 10_000_000 ether);
        escrow = new MyAIEscrow(address(token), coordinator, treasury);
        vm.stopPrank();

        address[] memory actors = new address[](5);
        actors[0] = address(0x1001);
        actors[1] = address(0x1002);
        actors[2] = address(0x1003);
        actors[3] = address(0x1004);
        actors[4] = address(0x1005);
        for (uint i = 0; i < actors.length; i++) {
            deal(address(token), actors[i], 100_000 ether);
        }

        handler = new EscrowHandler(escrow, token, coordinator, actors);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = handler.lockPayment.selector;
        sels[1] = handler.releasePayment.selector;
        sels[2] = handler.refundPayment.selector;
        sels[3] = handler.claimExpired.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_E1_lockedBackedByBalance() public view {
        uint256 sumLocked;
        uint256 n = handler.jobsCount();
        for (uint i = 0; i < n; i++) {
            bytes32 jobId = handler.allJobs(i);
            (, , uint256 amount, , uint256 lockedAt, MyAIEscrow.EscrowStatus status, ) = escrow.escrows(jobId);
            if (lockedAt != 0 && status == MyAIEscrow.EscrowStatus.Locked) {
                sumLocked += amount;
            }
        }
        assertLe(sumLocked, token.balanceOf(address(escrow)), "INV-E1");
    }

    function invariant_E2_terminalStatusIsSticky() public view {
        uint256 n = handler.jobsCount();
        for (uint i = 0; i < n; i++) {
            bytes32 jobId = handler.allJobs(i);
            (, , , , uint256 lockedAt, MyAIEscrow.EscrowStatus status, ) = escrow.escrows(jobId);
            if (lockedAt == 0) continue;
            if (status != MyAIEscrow.EscrowStatus.Locked) {
                assertTrue(
                    status == MyAIEscrow.EscrowStatus.Released ||
                    status == MyAIEscrow.EscrowStatus.Refunded ||
                    status == MyAIEscrow.EscrowStatus.Expired,
                    "INV-E2"
                );
            }
        }
    }

    function invariant_E4_settlementBookkeeping() public view {
        uint256 settled = handler.totalReleased() + handler.totalRefunded() + handler.totalExpired();
        assertLe(settled, handler.totalLocked(), "INV-E4");
    }

    function invariant_E5_balanceAccounting() public view {
        uint256 paidOut = handler.totalReleased() + handler.totalRefunded() + handler.totalExpired();
        uint256 expectedBalance = handler.totalLocked() - paidOut;
        assertEq(token.balanceOf(address(escrow)), expectedBalance, "INV-E5");
    }
}
