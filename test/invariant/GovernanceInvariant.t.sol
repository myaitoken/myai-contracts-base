// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIGovernance} from "../../contracts/MyAIGovernance.sol";
import {MyAIReputation} from "../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {GovernanceHandler} from "./handlers/GovernanceHandler.sol";

contract GovernanceInvariantTest is Test {
    MyAIGovernance public gov;
    MyAIReputation public rep;
    MockERC20 public token;
    GovernanceHandler public handler;

    address public owner = address(0xA11CE);
    address public coordinator = address(0xC00D);

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20("MyAI", "MYAI", 10_000_000 ether);
        rep = new MyAIReputation(coordinator, address(token));
        gov = new MyAIGovernance(address(rep));
        vm.stopPrank();

        address[] memory actors = new address[](5);
        for (uint160 i = 0; i < 5; i++) {
            actors[i] = address(uint160(0x3000) + i);
        }
        handler = new GovernanceHandler(gov, rep, coordinator, actors);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = handler.seedReputation.selector;
        sels[1] = handler.propose.selector;
        sels[2] = handler.vote.selector;
        sels[3] = handler.finalize.selector;
        sels[4] = handler.execute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_G2_voteCountMatches() public view {
        uint256 n = handler.proposalCount();
        for (uint i = 0; i < n; i++) {
            uint256 id = handler.proposalAt(i);
            MyAIGovernance.Proposal memory p = gov.getProposal(id);
            assertEq(p.votesFor, handler.ghostVotesFor(id), "INV-G2 for");
            assertEq(p.votesAgainst, handler.ghostVotesAgainst(id), "INV-G2 against");
            assertEq(p.totalVotingWeight, handler.ghostTotalWeight(id), "INV-G2 total");
        }
    }

    function invariant_G4_executedSticky() public view {
        uint256 n = handler.proposalCount();
        for (uint i = 0; i < n; i++) {
            uint256 id = handler.proposalAt(i);
            MyAIGovernance.Proposal memory p = gov.getProposal(id);
            if (handler.ghostExecuted(id)) {
                assertTrue(p.status == MyAIGovernance.ProposalStatus.Executed, "INV-G4");
            }
        }
    }

    function invariant_G3_passedRequiresMajority() public view {
        uint256 n = handler.proposalCount();
        for (uint i = 0; i < n; i++) {
            uint256 id = handler.proposalAt(i);
            MyAIGovernance.Proposal memory p = gov.getProposal(id);
            if (p.status == MyAIGovernance.ProposalStatus.Passed ||
                p.status == MyAIGovernance.ProposalStatus.Executed) {
                assertGt(p.votesFor, p.votesAgainst, "INV-G3");
            }
        }
    }
}
