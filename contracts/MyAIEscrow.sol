// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MyAIEscrow
 * @notice On-chain escrow for MyAI agent-to-agent compute payments.
 * @dev Requesters lock MYAI tokens when submitting jobs.
 *      Coordinator oracle releases/refunds based on Proof-of-Compute.
 *      20% of every payment is burned (BME mechanics).
 */
contract MyAIEscrow is ReentrancyGuard, Ownable, Pausable {
    IERC20 public immutable myaiToken;
    address public coordinator;  // Oracle: MyAI coordinator service

    // Fee split (basis points, total = 10000)
    uint256 public constant PROVIDER_BPS = 7300;  // 73% to provider
    uint256 public constant BURN_BPS     = 2000;  // 20% burned (BME)
    uint256 public constant PROTOCOL_BPS = 700;   // 7% to protocol treasury
    address public protocolTreasury;
    address public constant BURN_ADDRESS = address(0xdead);

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

    event PaymentLocked(bytes32 indexed jobId, address indexed requester, address indexed provider, uint256 amount);
    event PaymentReleased(bytes32 indexed jobId, address indexed provider, uint256 providerAmount, uint256 burned);
    event PaymentRefunded(bytes32 indexed jobId, address indexed requester, uint256 amount);
    event PaymentExpired(bytes32 indexed jobId, address indexed requester, uint256 amount);
    event CoordinatorUpdated(address indexed newCoordinator);

    modifier onlyCoordinator() {
        require(msg.sender == coordinator || msg.sender == owner(), "Not coordinator");
        _;
    }

    constructor(address _myaiToken, address _coordinator, address _treasury) Ownable(msg.sender) {
        myaiToken = IERC20(_myaiToken);
        coordinator = _coordinator;
        protocolTreasury = _treasury;
    }

    /**
     * @notice Lock MYAI payment when requester submits a job.
     * @param jobId Unique job identifier
     * @param provider Provider's wallet address
     * @param amount MYAI amount to lock (in wei)
     */
    function lockPayment(
        bytes32 jobId,
        address provider,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(escrows[jobId].lockedAt == 0, "Job already escrowed");
        require(provider != address(0), "Invalid provider");
        require(amount > 0, "Amount must be > 0");
        require(myaiToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

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

        emit PaymentLocked(jobId, msg.sender, provider, amount);
    }

    /**
     * @notice Release payment to provider after Proof-of-Compute verification.
     * @param jobId Job identifier
     * @param pocHash Hash of the verified compute output
     */
    function releasePayment(
        bytes32 jobId,
        bytes32 pocHash
    ) external onlyCoordinator nonReentrant {
        Escrow storage escrow = escrows[jobId];
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");
        require(escrow.lockedAt > 0, "Escrow not found");

        escrow.status = EscrowStatus.Released;
        escrow.pocHash = pocHash;

        uint256 total = escrow.amount;
        uint256 providerAmount = (total * PROVIDER_BPS) / 10000;
        uint256 burnAmount     = (total * BURN_BPS) / 10000;
        uint256 protocolAmount = total - providerAmount - burnAmount;

        require(myaiToken.transfer(escrow.provider, providerAmount), "Provider transfer failed");
        require(myaiToken.transfer(BURN_ADDRESS, burnAmount), "Burn transfer failed");
        require(myaiToken.transfer(protocolTreasury, protocolAmount), "Treasury transfer failed");

        emit PaymentReleased(jobId, escrow.provider, providerAmount, burnAmount);
    }

    /**
     * @notice Refund requester if PoC fails or job is cancelled.
     * @param jobId Job identifier
     */
    function refundPayment(bytes32 jobId) external onlyCoordinator nonReentrant {
        Escrow storage escrow = escrows[jobId];
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");

        escrow.status = EscrowStatus.Refunded;
        require(myaiToken.transfer(escrow.requester, escrow.amount), "Refund failed");

        emit PaymentRefunded(jobId, escrow.requester, escrow.amount);
    }

    /**
     * @notice Allow requester to claim expired escrow after timeout.
     */
    function claimExpired(bytes32 jobId) external nonReentrant {
        Escrow storage escrow = escrows[jobId];
        require(escrow.requester == msg.sender, "Not requester");
        require(escrow.status == EscrowStatus.Locked, "Escrow not active");
        require(block.timestamp > escrow.lockedAt + escrowTimeout, "Not expired yet");

        escrow.status = EscrowStatus.Expired;
        require(myaiToken.transfer(escrow.requester, escrow.amount), "Refund failed");

        emit PaymentExpired(jobId, escrow.requester, escrow.amount);
    }

    function getEscrow(bytes32 jobId) external view returns (Escrow memory) {
        return escrows[jobId];
    }

    function setCoordinator(address _coordinator) external onlyOwner {
        coordinator = _coordinator;
        emit CoordinatorUpdated(_coordinator);
    }

    function setEscrowTimeout(uint256 _timeout) external onlyOwner {
        escrowTimeout = _timeout;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
