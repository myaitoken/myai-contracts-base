// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MyAIReputation.sol";

/**
 * @title MyAIGovernance
 * @notice Agent-native governance where verified compute = voting weight.
 * @dev Voting weight = staked MYAI + governance points from verified jobs.
 *      Any agent with 100+ governance points can propose.
 *      48h timelock before execution.
 */
contract MyAIGovernance is Ownable {
    MyAIReputation public reputation;

    enum ProposalStatus { Pending, Active, Passed, Failed, Executed, Cancelled }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        bytes callData;               // Encoded function call to execute
        address target;               // Contract to call
        uint256 createdAt;
        uint256 votingEndsAt;
        uint256 executionAvailableAt; // createdAt + votingPeriod + timelock
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotingWeight;
        ProposalStatus status;
    }

    uint256 public proposalCount;
    uint256 public votingPeriod     = 3 days;
    uint256 public timelockPeriod   = 48 hours;
    uint256 public quorumBps        = 1000;  // 10% quorum
    uint256 public proposalThreshold = 100;  // 100 governance points to propose

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, address indexed proposer, string title);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalPassed(uint256 indexed id);
    event ProposalFailed(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);

    constructor(address _reputation) Ownable(msg.sender) {
        reputation = MyAIReputation(_reputation);
    }

    function getVotingWeight(address agent) public view returns (uint256) {
        MyAIReputation.AgentProfile memory profile = reputation.getProfile(agent);
        uint256 stakedWeight = profile.stakedAmount / 1e18; // 1 token = 1 weight
        return profile.governancePoints + stakedWeight;
    }

    function propose(
        string calldata title,
        string calldata description,
        address target,
        bytes calldata callData
    ) external returns (uint256) {
        require(getVotingWeight(msg.sender) >= proposalThreshold, "Insufficient governance points");

        proposalCount++;
        uint256 id = proposalCount;

        proposals[id] = Proposal({
            id: id,
            proposer: msg.sender,
            title: title,
            description: description,
            callData: callData,
            target: target,
            createdAt: block.timestamp,
            votingEndsAt: block.timestamp + votingPeriod,
            executionAvailableAt: block.timestamp + votingPeriod + timelockPeriod,
            votesFor: 0,
            votesAgainst: 0,
            totalVotingWeight: 0,
            status: ProposalStatus.Active
        });

        emit ProposalCreated(id, msg.sender, title);
        return id;
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp <= p.votingEndsAt, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 weight = getVotingWeight(msg.sender);
        require(weight > 0, "No voting weight");

        hasVoted[proposalId][msg.sender] = true;
        p.totalVotingWeight += weight;

        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function finalize(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > p.votingEndsAt, "Voting not ended");

        bool passed = p.votesFor > p.votesAgainst;

        if (passed) {
            p.status = ProposalStatus.Passed;
            emit ProposalPassed(proposalId);
        } else {
            p.status = ProposalStatus.Failed;
            emit ProposalFailed(proposalId);
        }
    }

    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Passed, "Not passed");
        require(block.timestamp >= p.executionAvailableAt, "Timelock not expired");

        p.status = ProposalStatus.Executed;

        if (p.target != address(0) && p.callData.length > 0) {
            (bool success,) = p.target.call(p.callData);
            require(success, "Execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }
}
