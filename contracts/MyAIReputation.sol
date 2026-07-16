// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title MyAIReputation
 * @notice On-chain reputation scoring for MyAI agents.
 * @dev Coordinator oracle records job completions.
 *      Reputation = weighted combination of success rate, PoC rate, and latency.
 *      Slashing for consecutive failures. Vouching for trust propagation.
 */
contract MyAIReputation is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;
    address public coordinator;
    IERC20 public immutable myaiToken;

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

    // ── Anti-sybil (audit #9700) ─────────────────────────────────────────────
    /// @notice Reputation a new agent starts with. Zero — reputation is EARNED
    ///         through coordinator-verified work (recordCompletion), never granted
    ///         for free at registration. Fixes audit #9700: previously register()
    ///         set the max score (10000), so an attacker could mass-register free
    ///         max-reputation identities and instantly clear the vouch threshold /
    ///         dominate getTopProviders.
    uint256 public constant INITIAL_REPUTATION = 0;
    /// @notice Minimum time between two vouches by the same voucher. Rate-limits
    ///         vouch spam so a single high-rep account cannot fan out trust to a
    ///         swarm of sybils in one block. Owner may not lower below this floor.
    uint256 public constant VOUCH_COOLDOWN = 1 days;

    /// @notice Minimum stake a voucher must hold to vouch. Gives vouching an
    ///         at-risk economic cost (audit #9700), so trust propagation is not
    ///         free/permissionless. Owner-tunable; the exact figure is an economic
    ///         parameter pending token-econ sign-off (see PR notes).
    uint256 public minVouchStake = 1_000 * 1e18;
    /// @notice Last time each address vouched (for VOUCH_COOLDOWN rate-limiting).
    mapping(address => uint256) public lastVouchAt;

    mapping(address => AgentProfile) public profiles;
    address[] public registeredAgents;

    /// @notice Running sum of every agent's current voting weight
    ///         (governancePoints + stakedAmount / 1e18). Maintained incrementally
    ///         so governance can read the quorum denominator in O(1) instead of
    ///         iterating every registered agent. Fixes audit #9687 (unbounded
    ///         on-chain loop -> permanent propose() DoS).
    uint256 public totalVotingWeight;

    /// @notice Block-numbered history of each agent's voting weight. Governance
    ///         measures a voter's weight as of a proposal's snapshot block, so
    ///         stake / governance points acquired AFTER proposal creation cannot
    ///         swing a live vote. Fixes audit #9686 (flash-stake takeover).
    mapping(address => Checkpoints.Trace208) private _weightCheckpoints;

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
        require(_coordinator != address(0), "Coordinator zero");
        require(_myaiToken   != address(0), "Token zero");
        coordinator = _coordinator;
        myaiToken = IERC20(_myaiToken);
    }

    function register() external {
        require(profiles[msg.sender].registeredAt == 0, "Already registered");
        profiles[msg.sender].reputationScore = INITIAL_REPUTATION; // earn it; no free max score (audit #9700)
        profiles[msg.sender].registeredAt = block.timestamp;
        profiles[msg.sender].lastUpdated = block.timestamp;
        registeredAgents.push(msg.sender);
        _syncVotingWeight(msg.sender);
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

        // Auto-register if not registered. Start at the earned-from-zero floor;
        // the score recalculation below immediately sets it from real job stats
        // (audit #9700 — no free max score on first sight of an agent).
        if (p.registeredAt == 0) {
            p.reputationScore = INITIAL_REPUTATION;
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
            uint256 latRef = p.avgLatencyMs;
            uint256 latencyScore = latRef < MAX_LATENCY_MS
                ? ((MAX_LATENCY_MS - latRef) * LATENCY_WEIGHT) / MAX_LATENCY_MS
                : 0;
            p.reputationScore = successScore + pocScore + latencyScore;
        }

        _syncVotingWeight(provider);
        emit JobRecorded(provider, pocPassed, p.reputationScore);
    }

    /**
     * @notice Stake MYAI tokens to boost reputation.
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        // Effects first (CEI) -- fix for slither H-1
        profiles[msg.sender].stakedAmount += amount;
        uint256 boost = (amount / 1e18) * 10;
        if (boost > 500) boost = 500;
        profiles[msg.sender].reputationScore =
            profiles[msg.sender].reputationScore + boost > 10000
            ? 10000
            : profiles[msg.sender].reputationScore + boost;
        // Checkpoint the new voting weight before the external interaction (CEI).
        _syncVotingWeight(msg.sender);
        // Interaction last
        myaiToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Vouch for another agent — trust propagation.
     */
    function vouch(address vouchee) external {
        require(msg.sender != vouchee, "Cannot vouch for self");

        AgentProfile storage voucher = profiles[msg.sender];
        // Voucher must have EARNED high reputation — a fresh/free account starts at
        // INITIAL_REPUTATION (0) and can never clear this on registration alone.
        require(voucher.reputationScore >= 9000, "Reputation too low to vouch");
        // Vouching carries an at-risk economic cost, so it is not permissionless
        // (audit #9700): a voucher must hold real stake to propagate trust.
        require(voucher.stakedAmount >= minVouchStake, "Insufficient stake to vouch");

        AgentProfile storage voucheeProfile = profiles[vouchee];
        for (uint i = 0; i < voucheeProfile.vouchedBy.length; i++) {
            require(voucheeProfile.vouchedBy[i] != msg.sender, "Already vouched");
        }

        // Rate-limit: a single voucher cannot fan trust out to a swarm of sybils
        // within one cooldown window (audit #9700).
        require(
            lastVouchAt[msg.sender] == 0 || block.timestamp >= lastVouchAt[msg.sender] + VOUCH_COOLDOWN,
            "Vouch cooldown active"
        );
        lastVouchAt[msg.sender] = block.timestamp;

        voucheeProfile.vouchedBy.push(msg.sender);
        if (voucheeProfile.reputationScore < 9900) {
            voucheeProfile.reputationScore += 100; // +1% per vouch from a staked, high-rep agent
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

    event CoordinatorUpdated(address indexed newCoordinator);
    event MinVouchStakeUpdated(uint256 newMinVouchStake);

    function setCoordinator(address _coordinator) external onlyOwner {
        require(_coordinator != address(0), "Zero address");
        coordinator = _coordinator;
        emit CoordinatorUpdated(_coordinator);
    }

    /// @notice Tune the minimum voucher stake (audit #9700 anti-sybil economic
    ///         parameter). Owner-gated; requires a non-zero floor so vouching can
    ///         never become permissionless again.
    function setMinVouchStake(uint256 newMinVouchStake) external onlyOwner {
        require(newMinVouchStake > 0, "Stake floor must be > 0");
        minVouchStake = newMinVouchStake;
        emit MinVouchStakeUpdated(newMinVouchStake);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Voting-weight accounting (governance snapshot support)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Current voting weight of an agent: governance points + staked whole
    ///      tokens. Mirrors MyAIGovernance.getVotingWeight so the two never drift.
    function _currentVotingWeight(address agent) internal view returns (uint256) {
        AgentProfile storage p = profiles[agent];
        return p.governancePoints + p.stakedAmount / 1e18;
    }

    /// @dev Record a checkpoint whenever an agent's voting weight changes and keep
    ///      the running total in sync. Same-block updates overwrite the value at
    ///      the existing key, so a snapshot always reflects the final weight for
    ///      its block.
    function _syncVotingWeight(address agent) internal {
        uint256 newWeight = _currentVotingWeight(agent);
        uint256 oldWeight = _weightCheckpoints[agent].latest();
        if (newWeight == oldWeight) return;
        // totalVotingWeight already includes this agent's oldWeight contribution.
        totalVotingWeight = totalVotingWeight - oldWeight + newWeight;
        _weightCheckpoints[agent].push(uint48(block.number), uint208(newWeight));
    }

    /// @notice Voting weight of `agent` as of `blockNumber` (inclusive). Governance
    ///         snapshots voting power at proposal creation with this, so weight
    ///         acquired in later blocks (flash-stake) does not count. Fixes #9686.
    function getPastVotingWeight(address agent, uint256 blockNumber)
        external view returns (uint256)
    {
        return _weightCheckpoints[agent].upperLookup(uint48(blockNumber));
    }

    function totalAgents() external view returns (uint256) {
        return registeredAgents.length;
    }
}
