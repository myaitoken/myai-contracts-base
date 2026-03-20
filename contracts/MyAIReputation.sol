// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MyAIReputation
 * @notice On-chain reputation scoring for MyAI agents.
 * @dev Coordinator oracle records job completions.
 *      Reputation = weighted combination of success rate, PoC rate, and latency.
 *      Slashing for consecutive failures. Vouching for trust propagation.
 */
contract MyAIReputation is Ownable {
    address public coordinator;
    IERC20 public myaiToken;

    struct AgentProfile {
        uint256 totalJobs;
        uint256 successfulJobs;
        uint256 pocVerifiedJobs;
        uint256 failedJobs;
        uint256 avgLatencyMs;
        uint256 reputationScore;     // 0-10000 (basis points, 10000 = 100.00)
        uint256 stakedAmount;
        uint256 consecutiveFailures;
        bool isSlashed;
        uint256 slashCooldownUntil;
        uint256 governancePoints;    // Earned from verified jobs
        address[] vouchedBy;
        uint256 registeredAt;
        uint256 lastUpdated;
    }

    // Reputation score weights (basis points)
    uint256 public constant SUCCESS_WEIGHT    = 5000;  // 50%
    uint256 public constant POC_WEIGHT        = 3000;  // 30%
    uint256 public constant LATENCY_WEIGHT    = 2000;  // 20%
    uint256 public constant MAX_LATENCY_MS    = 30000; // 30s = 0 latency score
    uint256 public constant SLASH_THRESHOLD   = 3;     // 3 consecutive failures
    uint256 public constant SLASH_PENALTY_BPS = 1000;  // 10% penalty
    uint256 public constant SLASH_COOLDOWN    = 48 hours;
    uint256 public constant GOVERNANCE_PER_JOB = 1;    // 1 gov point per verified job

    mapping(address => AgentProfile) public profiles;
    address[] public registeredAgents;

    event AgentRegistered(address indexed agent, uint256 timestamp);
    event JobRecorded(address indexed provider, bool pocPassed, uint256 newScore);
    event AgentSlashed(address indexed agent, uint256 penalty, uint256 cooldownUntil);
    event AgentVouched(address indexed voucher, address indexed vouchee);
    event Staked(address indexed agent, uint256 amount);
    event Unstaked(address indexed agent, uint256 amount);

    modifier onlyCoordinator() {
        require(msg.sender == coordinator || msg.sender == owner(), "Not coordinator");
        _;
    }

    constructor(address _coordinator, address _myaiToken) Ownable(msg.sender) {
        coordinator = _coordinator;
        myaiToken = IERC20(_myaiToken);
    }

    function register() external {
        require(profiles[msg.sender].registeredAt == 0, "Already registered");
        profiles[msg.sender].reputationScore = 10000; // Start at 100.00
        profiles[msg.sender].registeredAt = block.timestamp;
        profiles[msg.sender].lastUpdated = block.timestamp;
        registeredAgents.push(msg.sender);
        emit AgentRegistered(msg.sender, block.timestamp);
    }

    /**
     * @notice Record job completion. Called by coordinator oracle.
     */
    function recordCompletion(
        address provider,
        bool pocPassed,
        uint256 latencyMs,
        uint256 tokensGenerated
    ) external onlyCoordinator {
        AgentProfile storage p = profiles[provider];

        // Auto-register if not registered
        if (p.registeredAt == 0) {
            p.reputationScore = 10000;
            p.registeredAt = block.timestamp;
            registeredAgents.push(provider);
        }

        p.totalJobs++;
        p.lastUpdated = block.timestamp;

        if (pocPassed) {
            p.successfulJobs++;
            p.pocVerifiedJobs++;
            p.consecutiveFailures = 0;
            p.governancePoints += GOVERNANCE_PER_JOB;
            // Update running average latency
            p.avgLatencyMs = (p.avgLatencyMs * (p.totalJobs - 1) + latencyMs) / p.totalJobs;

            // Reset slash if cooldown passed
            if (p.isSlashed && block.timestamp > p.slashCooldownUntil) {
                p.isSlashed = false;
                p.consecutiveFailures = 0;
            }
        } else {
            p.failedJobs++;
            p.consecutiveFailures++;

            // Slashing
            if (p.consecutiveFailures >= SLASH_THRESHOLD && !p.isSlashed) {
                uint256 penalty = (p.reputationScore * SLASH_PENALTY_BPS) / 10000;
                p.reputationScore = p.reputationScore > penalty ? p.reputationScore - penalty : 0;
                p.isSlashed = true;
                p.slashCooldownUntil = block.timestamp + SLASH_COOLDOWN;
                emit AgentSlashed(provider, penalty, p.slashCooldownUntil);
            }
        }

        // Recalculate score
        if (p.totalJobs > 0) {
            uint256 successScore = (p.successfulJobs * SUCCESS_WEIGHT) / p.totalJobs;
            uint256 pocScore     = (p.pocVerifiedJobs * POC_WEIGHT) / p.totalJobs;
            uint256 latencyScore = latencyMs < MAX_LATENCY_MS
                ? ((MAX_LATENCY_MS - latencyMs) * LATENCY_WEIGHT) / MAX_LATENCY_MS
                : 0;
            p.reputationScore = successScore + pocScore + latencyScore;
        }

        emit JobRecorded(provider, pocPassed, p.reputationScore);
    }

    /**
     * @notice Stake MYAI tokens to boost reputation.
     */
    function stake(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        require(myaiToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        profiles[msg.sender].stakedAmount += amount;
        uint256 boost = (amount / 1e18) * 10; // 10bp per token staked
        if (boost > 500) boost = 500;          // Max 5% boost from staking
        profiles[msg.sender].reputationScore =
            profiles[msg.sender].reputationScore + boost > 10000
            ? 10000
            : profiles[msg.sender].reputationScore + boost;
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Vouch for another agent — trust propagation.
     */
    function vouch(address vouchee) external {
        AgentProfile storage voucher = profiles[msg.sender];
        require(voucher.reputationScore >= 9000, "Reputation too low to vouch");
        require(msg.sender != vouchee, "Cannot vouch for self");

        AgentProfile storage voucheeProfile = profiles[vouchee];
        for (uint i = 0; i < voucheeProfile.vouchedBy.length; i++) {
            require(voucheeProfile.vouchedBy[i] != msg.sender, "Already vouched");
        }

        voucheeProfile.vouchedBy.push(msg.sender);
        if (voucheeProfile.reputationScore < 9900) {
            voucheeProfile.reputationScore += 100; // +1% per vouch from 90+ rep agent
        }

        emit AgentVouched(msg.sender, vouchee);
    }

    function getProfile(address agent) external view returns (AgentProfile memory) {
        return profiles[agent];
    }

    function getTopProviders(uint256 minScore, uint256 limit)
        external view returns (address[] memory, uint256[] memory)
    {
        address[] memory top    = new address[](limit);
        uint256[] memory scores = new uint256[](limit);
        uint256 count = 0;

        for (uint i = 0; i < registeredAgents.length && count < limit; i++) {
            address agent = registeredAgents[i];
            if (profiles[agent].reputationScore >= minScore && !profiles[agent].isSlashed) {
                top[count]    = agent;
                scores[count] = profiles[agent].reputationScore;
                count++;
            }
        }
        return (top, scores);
    }

    function setCoordinator(address _coordinator) external onlyOwner {
        coordinator = _coordinator;
    }

    function totalAgents() external view returns (uint256) {
        return registeredAgents.length;
    }
}
