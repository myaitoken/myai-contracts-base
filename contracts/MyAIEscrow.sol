// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MyAIEscrow
 * @notice On-chain escrow for MyAI agent-to-agent compute payments.
 * @dev Requesters lock MYAI tokens when submitting jobs.
 *      Coordinator oracle releases/refunds based on Proof-of-Compute.
 *      20% of every payment is burned (BME mechanics).
 *      Protocol fee starts at 3% (feeBps=300) and is adjustable by owner (max 10%).
 */
contract MyAIEscrow is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    IERC20 public immutable myaiToken;
    address public coordinator;  // Oracle: MyAI coordinator service

    // Burn BPS is constant — immutable BME mechanic
    uint256 public constant BURN_BPS = 2000;       // 20% burned
    uint256 public constant MAX_FEE_BPS = 1000;    // Protocol fee ceiling: 10%
    address public constant BURN_ADDRESS = address(0xdead);

    // Adjustable protocol fee: starts at 3%, owner can change within MAX_FEE_BPS
    uint256 public feeBps = 300;   // 3% default
    address public protocolTreasury;

    struct Escrow {
        address requester;
        address provider;
        uint256 amount;
        bytes32 jobId;
        uint256 lockedAt;
        EscrowStatus status;
        bytes32 pocHash;  // Proof-of-Compute hash
    }

    enum EscrowStatus { Locked, Released, Refunded, Expired }

    uint256 public escrowTimeout = 1 hours;

    mapping(bytes32 => Escrow) public escrows;
    bytes32[] public escrowIds;

    // Cumulative fee tracking
    uint256 public totalFeesEarned;
    uint256 public totalBurned;

    event PaymentLocked(bytes32 indexed jobId, address indexed requester, address indexed provider, uint256 amount);
    event PaymentReleased(bytes32 indexed jobId, address indexed provider, uint256 providerAmount, uint256 burned, uint256 fee);
    event PaymentRefunded(bytes32 indexed jobId, address indexed requester, uint256 amount);
    event PaymentExpired(bytes32 indexed jobId, address indexed requester, uint256 amount);
    event CoordinatorUpdated(address indexed newCoordinator);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event TreasuryUpdated(address indexed newTreasury);
    event EscrowTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    modifier onlyCoordinator() {
        require(msg.sender == coordinator || msg.sender == owner(), "Not coordinator");
        _;
    }

    constructor(address _myaiToken, address _coordinator, address _treasury) Ownable(msg.sender) {
        require(_myaiToken != address(0), "Token zero");
        require(_coordinator != address(0), "Coordinator zero");
        require(_treasury != address(0), "Treasury zero");
        myaiToken = IERC20(_myaiToken);
        coordinator = _coordinator;
        protocolTreasury = _treasury;
    }

    // ─── Locking ─────────────────────────────────────────────────────────────

    function lockPayment(
        bytes32 jobId,
        address provider,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(escrows[jobId].lockedAt == 0, "Job already escrowed");
        require(provider != address(0), "Invalid provider");
        require(amount > 0, "Amount must be > 0");

        // Effects first (CEI) -- fix for slither H-1 reentrancy-no-eth
        escrows[jobId] = Escrow({
            requester: msg.sender,
            provider: provider,
            amount: amount,
            jobId: jobId,
            lockedAt: block.timestamp,
            status: EscrowStatus.Locked,
            pocHash: bytes32(0)
        });
        escrowIds.push(jobId);

        // Interaction last
        myaiToken.safeTransferFrom(msg.sender, address(this), amount);

        emit PaymentLocked(jobId, msg.sender, provider, amount);
    }

    // ─── Settlement ───────────────────────────────────────────────────────────

    function releasePayment(
        bytes32 jobId,
        bytes32 pocHash
    ) external nonReentrant onlyCoordinator {
        Escrow storage escrow = escrows[jobId];
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");
        require(escrow.lockedAt > 0, "Escrow not found");

        escrow.status = EscrowStatus.Released;
        escrow.pocHash = pocHash;

        uint256 total = escrow.amount;
        uint256 feeAmount      = (total * feeBps) / 10000;
        uint256 burnAmount     = (total * BURN_BPS) / 10000;
        uint256 providerAmount = total - feeAmount - burnAmount;

        totalFeesEarned += feeAmount;
        totalBurned     += burnAmount;

        myaiToken.safeTransfer(escrow.provider, providerAmount);
        myaiToken.safeTransfer(BURN_ADDRESS, burnAmount);
        if (feeAmount > 0) {
            myaiToken.safeTransfer(protocolTreasury, feeAmount);
        }

        emit PaymentReleased(jobId, escrow.provider, providerAmount, burnAmount, feeAmount);
    }

    function refundPayment(bytes32 jobId) external nonReentrant onlyCoordinator {
        Escrow storage escrow = escrows[jobId];
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");

        escrow.status = EscrowStatus.Refunded;
        myaiToken.safeTransfer(escrow.requester, escrow.amount);

        emit PaymentRefunded(jobId, escrow.requester, escrow.amount);
    }

    function claimExpired(bytes32 jobId) external nonReentrant {
        Escrow storage escrow = escrows[jobId];
        require(escrow.requester == msg.sender, "Not requester");
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");
        require(block.timestamp > escrow.lockedAt + escrowTimeout, "Not expired yet");

        escrow.status = EscrowStatus.Expired;
        myaiToken.safeTransfer(escrow.requester, escrow.amount);

        emit PaymentExpired(jobId, escrow.requester, escrow.amount);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function getEscrow(bytes32 jobId) external view returns (Escrow memory) {
        return escrows[jobId];
    }

    function previewSplit(uint256 amount) external view returns (
        uint256 providerAmount,
        uint256 burnAmount,
        uint256 feeAmount
    ) {
        feeAmount      = (amount * feeBps) / 10000;
        burnAmount     = (amount * BURN_BPS) / 10000;
        providerAmount = amount - feeAmount - burnAmount;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "Exceeds 10% cap");
        emit FeeBpsUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    function setCoordinator(address _coordinator) external onlyOwner {
        require(_coordinator != address(0), "Zero address");
        coordinator = _coordinator;
        emit CoordinatorUpdated(_coordinator);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Zero address");
        protocolTreasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setEscrowTimeout(uint256 _timeout) external onlyOwner {
        require(_timeout >= 5 minutes && _timeout <= 30 days, "Timeout out of range");
        emit EscrowTimeoutUpdated(escrowTimeout, _timeout);
        escrowTimeout = _timeout;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
