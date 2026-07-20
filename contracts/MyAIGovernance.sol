// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MyAIReputation.sol";

/**
 * @title MyAIGovernance
 * @notice Agent-native governance where verified compute = voting weight.
 * @dev Voting weight = staked MYAI + governance points from verified jobs.
 *      Any agent with 100+ governance points can propose.
 *      48h timelock before execution.
 *      Quorum: participation (votesFor + votesAgainst) must be >= quorumBps
 *      of the total eligible voting weight snapshotted at proposal creation.
 */
contract MyAIGovernance is Ownable, ReentrancyGuard {
    MyAIReputation public immutable reputation;

    enum ProposalStatus { Pending, Active, Passed, Failed, Executed, Cancelled }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        bytes callData;                  // Encoded function call to execute
        address target;                  // Contract to call
        uint256 createdAt;
        uint256 votingEndsAt;
        uint256 executionAvailableAt;    // createdAt + votingPeriod + timelock
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotingWeight;
        uint256 eligibleVotingWeight;    // Snapshot of total eligible weight at creation
        ProposalStatus status;
    }

    uint256 public proposalCount;
    uint256 public votingPeriod      = 3 days;
    uint256 public timelockPeriod    = 48 hours;
    uint256 public quorumBps         = 1000;  // 10% quorum
    uint256 public proposalThreshold = 100;   // 100 governance points to propose

    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Block number snapshotted at each proposal's creation. Per-voter
    ///         voting weight is measured as of this block so stake / governance
    ///         points acquired later cannot swing the vote. Fixes #9686.
    mapping(uint256 => uint256) public proposalSnapshotBlock;

    /// @dev Reverts when finalize() is called and participation < quorumBps.
    error QuorumNotMet(uint256 participationBps, uint256 requiredBps);

    event ProposalCreated(uint256 indexed id, address indexed proposer, string title, uint256 eligibleVotingWeight);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalPassed(uint256 indexed id);
    event ProposalFailed(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);

    /// @notice Owner-curated allowlist of contracts a passed proposal may call in
    ///         execute(). Without it, execute() would make an arbitrary external
    ///         call to any proposer-encoded (target, callData) — e.g. draining
    ///         funds, granting roles, or self-upgrading. The owner is intended to be
    ///         the MyAITimelock + multisig, and can flip a target off during the 48h
    ///         execution timelock to defuse a malicious-but-passed proposal.
    ///         Fixes audit #9670 (arbitrary-call execute()).
    mapping(address => bool) public allowedTarget;

    event TargetAllowed(address indexed target, bool allowed);

    constructor(address _reputation) Ownable(msg.sender) {
        require(_reputation != address(0), "Reputation zero");
        reputation = MyAIReputation(_reputation);
    }

    /// @notice Owner adds/removes a contract from the execute() target allowlist.
    /// @dev Owner is intended to be the MyAITimelock + multisig. address(0) can never
    ///      be allowlisted — it is the sentinel for no-op / signaling proposals.
    function setTargetAllowed(address target, bool allowed) external onlyOwner {
        require(target != address(0), "Zero target");
        allowedTarget[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function getVotingWeight(address agent) public view returns (uint256) {
        MyAIReputation.AgentProfile memory profile = reputation.getProfile(agent);
        uint256 stakedWeight = profile.stakedAmount / 1e18; // 1 token = 1 weight
        return profile.governancePoints + stakedWeight;
    }

    /**
     * @notice Total eligible voting weight, used as the quorum denominator snapshot.
     * @dev O(1): reads the running total maintained inside MyAIReputation instead of
     *      iterating every registered agent. The previous O(N) loop over
     *      registeredAgents was called from propose(); once the permissionless agent
     *      set grew large enough, propose() exceeded the block gas limit and was
     *      permanently bricked. Fixes audit #9687 (unbounded-loop propose() DoS).
     */
    function getTotalEligibleVotingWeight() public view returns (uint256) {
        return reputation.totalVotingWeight();
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

        uint256 eligible = getTotalEligibleVotingWeight();

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
            eligibleVotingWeight: eligible,
            status: ProposalStatus.Active
        });
        proposalSnapshotBlock[id] = block.number;

        emit ProposalCreated(id, msg.sender, title, eligible);
        return id;
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp <= p.votingEndsAt, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        // Snapshot voting: count weight as of the proposal-creation block, so an
        // attacker cannot flash-stake / farm points AFTER a proposal exists to swing
        // the vote, then unwind. Fixes audit #9686 (flash-stake takeover).
        uint256 weight = reputation.getPastVotingWeight(msg.sender, proposalSnapshotBlock[proposalId]);
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

    /**
     * @notice Tally a proposal after voting ends. Enforces quorum:
     *         (votesFor + votesAgainst) * 10000 / eligibleVotingWeight >= quorumBps.
     *         Reverts with QuorumNotMet otherwise (proposal stays Active so
     *         participants can still vote up to votingEndsAt; once past that,
     *         under-quorum proposals are effectively dead).
     */
    function finalize(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > p.votingEndsAt, "Voting not ended");

        uint256 turnout = p.votesFor + p.votesAgainst;
        uint256 eligible = p.eligibleVotingWeight;

        if (eligible > 0) {
            uint256 participationBps = (turnout * BPS_DENOMINATOR) / eligible;
            if (participationBps < quorumBps) {
                revert QuorumNotMet(participationBps, quorumBps);
            }
        }
        // If eligible == 0 we treat the proposal as fail-safe failed below
        // (votesFor cannot exceed votesAgainst with no electorate).

        bool passed = p.votesFor > p.votesAgainst;

        if (passed) {
            p.status = ProposalStatus.Passed;
            emit ProposalPassed(proposalId);
        } else {
            p.status = ProposalStatus.Failed;
            emit ProposalFailed(proposalId);
        }
    }

    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Passed, "Not passed");
        require(block.timestamp >= p.executionAvailableAt, "Timelock not expired");

        p.status = ProposalStatus.Executed;

        if (p.target != address(0) && p.callData.length > 0) {
            // Arbitrary-call hardening (#9670): a passed proposal may only call a
            // target the owner (Timelock+multisig) has explicitly allowlisted. The
            // check is at execution time, so the owner can revoke a target during
            // the 48h timelock to neutralise a malicious proposal that slipped
            // through voting. Together with the timelock delay and nonReentrant,
            // execute() can no longer make an unconstrained external call.
            require(allowedTarget[p.target], "Target not allowlisted");
            (bool success,) = p.target.call(p.callData);
            require(success, "Execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }
}
