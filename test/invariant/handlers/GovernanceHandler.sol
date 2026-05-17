// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MyAIGovernance} from "../../../contracts/MyAIGovernance.sol";
import {MyAIReputation} from "../../../contracts/MyAIReputation.sol";

contract GovernanceHandler is CommonBase, StdCheats, StdUtils {
    MyAIGovernance public gov;
    MyAIReputation public rep;
    address public coordinator;
    address[] public actors;

    mapping(uint256 => uint256) public ghostVotesFor;
    mapping(uint256 => uint256) public ghostVotesAgainst;
    mapping(uint256 => uint256) public ghostTotalWeight;
    mapping(uint256 => mapping(address => bool)) public ghostHasVoted;
    mapping(uint256 => bool) public ghostExecuted;
    uint256[] public allProposals;

    constructor(MyAIGovernance _gov, MyAIReputation _rep, address _coordinator, address[] memory _actors) {
        gov = _gov;
        rep = _rep;
        coordinator = _coordinator;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function seedReputation(uint256 actorSeed, uint256 jobs) external {
        address a = _actor(actorSeed);
        jobs = bound(jobs, 1, 50);
        vm.startPrank(coordinator);
        for (uint i = 0; i < jobs; i++) {
            try rep.recordCompletion(a, true, 1000, 100) {} catch {}
        }
        vm.stopPrank();
    }

    function propose(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try gov.propose("title", "desc", address(0), "") returns (uint256 id) {
            allProposals.push(id);
        } catch {}
    }

    function vote(uint256 actorSeed, uint256 propSeed, bool support) external {
        if (allProposals.length == 0) return;
        uint256 id = allProposals[bound(propSeed, 0, allProposals.length - 1)];
        address a = _actor(actorSeed);
        if (ghostHasVoted[id][a]) return;
        uint256 weight = gov.getVotingWeight(a);
        vm.prank(a);
        try gov.vote(id, support) {
            ghostHasVoted[id][a] = true;
            ghostTotalWeight[id] += weight;
            if (support) ghostVotesFor[id] += weight;
            else ghostVotesAgainst[id] += weight;
        } catch {}
    }

    function finalize(uint256 propSeed, uint256 warpBy) external {
        if (allProposals.length == 0) return;
        uint256 id = allProposals[bound(propSeed, 0, allProposals.length - 1)];
        warpBy = bound(warpBy, 1, 30 days);
        vm.warp(block.timestamp + warpBy);
        try gov.finalize(id) {} catch {}
    }

    function execute(uint256 propSeed, uint256 warpBy) external {
        if (allProposals.length == 0) return;
        uint256 id = allProposals[bound(propSeed, 0, allProposals.length - 1)];
        warpBy = bound(warpBy, 1, 30 days);
        vm.warp(block.timestamp + warpBy);
        try gov.execute(id) {
            ghostExecuted[id] = true;
        } catch {}
    }

    function proposalCount() external view returns (uint256) { return allProposals.length; }
    function proposalAt(uint256 i) external view returns (uint256) { return allProposals[i]; }
}
