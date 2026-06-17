// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title MyAi Protocol Escrow (LEGACY — DEPRECATED)
 * @custom:deprecated Superseded by MyAIEscrow.sol. This is the source of the
 *   originally-deployed escrow (Base 0x280Be8…); it LACKS refund()/selfRefund().
 *   Kept only for provenance of the live bytecode. NOT in the audit scope and
 *   intentionally untested — do NOT deploy. The canonical escrow is MyAIEscrow
 *   (refund/selfRefund + adjustable fee); see board card 9394 for the V2
 *   on-chain redeploy that replaces this contract.
 *
 * @notice Holds MYAI tokens in escrow per job, releases them to the agent on
 *         completion, applying a configurable protocol fee split between a
 *         treasury address and the burn (dead) address.
 * @dev    Deployed on Base mainnet (chainId 8453).
 *         No external dependencies — fully self-contained.
 *
 * Security changelog (audit remediation 2026-05-20)
 * --------------------------------------------------
 *   [HIGH]  Two-step ownership transfer via pendingOwner + acceptOwnership().
 *   [HIGH]  Depositor stored in Job struct; refund() uses stored address,
 *           removing owner's ability to misdirect refunds.
 *   [MED]   Fee parameters (FEE_BPS, BURN_BPS) snapshotted at deposit time,
 *           protecting depositors from retroactive fee changes.
 *   [MED]   Self-refund escape hatch: depositor may claim back funds after
 *           REFUND_TIMEOUT if owner has not released or refunded.
 *   [MED]   Zero-address guard added to setTreasury already existed; added
 *           zero-address guard on pendingOwner acceptance path.
 *
 * Fee model
 * ---------
 *   totalFee   = amount * feeBps  / 10_000          (snapshotted at deposit)
 *   burnAmount = totalFee * burnBps / 10_000         (snapshotted at deposit)
 *   feeAmount  = totalFee - burnAmount               (goes to treasury)
 *   provider   = amount - totalFee
 *
 * Governance parameters (owner-adjustable, affect new deposits only)
 * ------------------------------------------------------------------
 *   FEE_BPS  — protocol fee in basis points; capped at 1_000 (10 %)
 *   BURN_BPS — share of the fee that is burned; 0–10_000 (0–100 %)
 */

// ---------------------------------------------------------------------------
// Minimal ERC-20 interface
// ---------------------------------------------------------------------------
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ---------------------------------------------------------------------------
// Escrow contract
// ---------------------------------------------------------------------------
contract Escrow {

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice The ERC-20 token accepted by this escrow (MYAI on Base).
    IERC20 public immutable token;

    /// @dev Dead address used for burns.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Basis-point denominator.
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Duration after which a depositor may self-refund if the owner
    ///         has not acted (released or refunded).
    uint256 public constant REFUND_TIMEOUT = 7 days;

    // -----------------------------------------------------------------------
    // Governance state
    // -----------------------------------------------------------------------

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in a two-step ownership transfer.
    ///         Zero address means no transfer is in progress.
    address public pendingOwner;

    /// @notice Protocol fee in basis points (default 300 = 3 %).
    ///         Only affects deposits made after this value is set.
    uint256 public FEE_BPS = 300;

    /// @notice Share of the fee directed to the burn address, in basis points
    ///         of the fee (default 5_000 = 50 %).
    ///         Only affects deposits made after this value is set.
    uint256 public BURN_BPS = 5_000;

    /// @notice Address that receives the non-burned portion of the protocol fee.
    address public treasury;

    // -----------------------------------------------------------------------
    // Job storage
    // -----------------------------------------------------------------------

    /// @notice On-chain representation of a single escrow job.
    struct Job {
        /// @dev Agent wallet that will receive payment on release.
        address agent;
        /// @dev Address that deposited the tokens; recipient of any refund.
        address depositor;
        /// @dev Total tokens locked into escrow for this job.
        uint256 amount;
        /// @dev Fee rate (bps) snapshotted at deposit time.
        uint16 feeBps;
        /// @dev Burn share (bps of fee) snapshotted at deposit time.
        uint16 burnBps;
        /// @dev Timestamp of the deposit; used for self-refund timeout.
        uint40 depositedAt;
        /// @dev True once `release()` has been called successfully.
        bool released;
        /// @dev True once `refund()` or `selfRefund()` has been called.
        bool refunded;
        /// @dev Proof-of-completion hash; set at release time.
        bytes32 pocHash;
    }

    /// @notice jobId → Job mapping.
    mapping(bytes32 => Job) public jobs;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a payer deposits tokens into escrow.
    event Deposited(
        bytes32 indexed jobId,
        address indexed agent,
        address indexed depositor,
        uint256 amount,
        uint16  feeBps,
        uint16  burnBps
    );

    /// @notice Emitted when a job is released to the agent.
    event Released(
        bytes32 indexed jobId,
        address indexed agent,
        uint256 amount,
        bytes32 pocHash
    );

    /// @notice Emitted when a job is refunded to the depositor.
    event Refunded(bytes32 indexed jobId, address indexed depositor, uint256 amount);

    /// @notice Emitted once per release when a protocol fee is applied.
    event ProtocolFeeCharged(bytes32 indexed jobId, uint256 burnAmount, uint256 feeAmount);

    /// @notice Emitted whenever the protocol fee rate is updated.
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted whenever the burn share is updated.
    event BurnBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted whenever the treasury address is updated.
    event TreasuryUpdated(address indexed previous, address indexed next);

    /// @notice Emitted when a two-step ownership transfer is initiated.
    event OwnershipTransferStarted(address indexed previous, address indexed next);

    /// @notice Emitted when a two-step ownership transfer is completed.
    event OwnershipTransferred(address indexed previous, address indexed next);

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "Escrow: not owner");
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @param _token    Address of the MYAI ERC-20 token on Base.
     * @param _treasury Initial treasury address for protocol fee collection.
     */
    constructor(address _token, address _treasury) {
        require(_token    != address(0), "Escrow: zero token");
        require(_treasury != address(0), "Escrow: zero treasury");
        token    = IERC20(_token);
        treasury = _treasury;
        owner    = msg.sender;
    }

    // -----------------------------------------------------------------------
    // Core functions
    // -----------------------------------------------------------------------

    /**
     * @notice Deposit tokens into escrow for a specific job.
     * @dev    The caller must have approved this contract for at least `amount`
     *         tokens beforehand. Fee parameters are snapshotted at deposit time
     *         so future governance changes do not affect existing jobs.
     * @param jobId  Unique identifier for the job (e.g. keccak256 of job UUID).
     * @param agent  Wallet address of the agent that will do the work.
     * @param amount Number of MYAI tokens (in smallest unit) to lock.
     */
    function deposit(bytes32 jobId, address agent, uint256 amount) external {
        require(jobs[jobId].agent == address(0), "Escrow: job exists");
        require(agent  != address(0), "Escrow: zero agent");
        require(amount  > 0,          "Escrow: zero amount");

        uint16 _feeBps  = uint16(FEE_BPS);
        uint16 _burnBps = uint16(BURN_BPS);

        jobs[jobId] = Job({
            agent:       agent,
            depositor:   msg.sender,
            amount:      amount,
            feeBps:      _feeBps,
            burnBps:     _burnBps,
            depositedAt: uint40(block.timestamp),
            released:    false,
            refunded:    false,
            pocHash:     bytes32(0)
        });

        require(
            token.transferFrom(msg.sender, address(this), amount),
            "Escrow: transferFrom failed"
        );

        emit Deposited(jobId, agent, msg.sender, amount, _feeBps, _burnBps);
    }

    /**
     * @notice Release escrowed tokens to the agent, applying the snapshotted
     *         protocol fee.
     * @dev    Only callable by the owner (coordinator/relayer). Uses the fee
     *         parameters captured at deposit time.
     * @param jobId   The job to settle.
     * @param pocHash Proof-of-completion hash (e.g. IPFS CID or result digest).
     */
    function release(bytes32 jobId, bytes32 pocHash) external onlyOwner {
        Job storage job = jobs[jobId];
        require(job.agent    != address(0), "Escrow: unknown job");
        require(!job.released,              "Escrow: already released");
        require(!job.refunded,              "Escrow: already refunded");

        // Store proof-of-completion before any external calls (CEI pattern).
        job.pocHash  = pocHash;
        job.released = true;

        (uint256 providerAmount, uint256 burnAmount, uint256 feeAmount) =
            _computeSplit(job.amount, job.feeBps, job.burnBps);

        require(
            token.transfer(job.agent, providerAmount),
            "Escrow: provider transfer failed"
        );

        if (burnAmount > 0) {
            require(
                token.transfer(DEAD, burnAmount),
                "Escrow: burn transfer failed"
            );
        }

        if (feeAmount > 0) {
            require(
                token.transfer(treasury, feeAmount),
                "Escrow: treasury transfer failed"
            );
        }

        emit ProtocolFeeCharged(jobId, burnAmount, feeAmount);
        emit Released(jobId, job.agent, providerAmount, pocHash);
    }

    /**
     * @notice Refund escrowed tokens to the stored depositor.
     * @dev    Only callable by the owner. Uses the depositor address captured
     *         at deposit time — eliminates the risk of owner misdirecting funds.
     *         No fee is charged on refunds.
     * @param jobId The job to refund.
     */
    function refund(bytes32 jobId) external onlyOwner {
        Job storage job = jobs[jobId];
        require(job.agent    != address(0), "Escrow: unknown job");
        require(!job.released,              "Escrow: already released");
        require(!job.refunded,              "Escrow: already refunded");

        address depositor = job.depositor;
        job.refunded = true;

        require(
            token.transfer(depositor, job.amount),
            "Escrow: refund transfer failed"
        );

        emit Refunded(jobId, depositor, job.amount);
    }

    /**
     * @notice Allows the original depositor to reclaim their tokens if the
     *         owner has not released or refunded after REFUND_TIMEOUT (7 days).
     * @dev    Escape hatch protecting depositors from owner inactivity or loss
     *         of keys. No fee is charged.
     * @param jobId The job to self-refund.
     */
    function selfRefund(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        require(job.agent      != address(0),                    "Escrow: unknown job");
        require(!job.released,                                   "Escrow: already released");
        require(!job.refunded,                                   "Escrow: already refunded");
        require(msg.sender     == job.depositor,                 "Escrow: not depositor");
        require(block.timestamp >= uint256(job.depositedAt) + REFUND_TIMEOUT,
                                                                 "Escrow: timeout not elapsed");

        job.refunded = true;

        require(
            token.transfer(job.depositor, job.amount),
            "Escrow: self-refund transfer failed"
        );

        emit Refunded(jobId, job.depositor, job.amount);
    }

    // -----------------------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Preview how a given `amount` would be split on release using the
     *         *current* global fee parameters (i.e. for new deposits).
     * @param amount Token amount to split (in smallest unit).
     * @return providerAmount Net amount the agent would receive.
     * @return burnAmount     Tokens that would be burned.
     * @return feeAmount      Tokens that would go to the treasury.
     */
    function previewSplit(uint256 amount)
        public
        view
        returns (
            uint256 providerAmount,
            uint256 burnAmount,
            uint256 feeAmount
        )
    {
        return _computeSplit(amount, uint16(FEE_BPS), uint16(BURN_BPS));
    }

    /**
     * @notice Preview the split that would apply on release for an existing job,
     *         using the fee parameters snapshotted at deposit time.
     * @param jobId The job to preview.
     */
    function previewJobSplit(bytes32 jobId)
        public
        view
        returns (
            uint256 providerAmount,
            uint256 burnAmount,
            uint256 feeAmount
        )
    {
        Job storage job = jobs[jobId];
        require(job.agent != address(0), "Escrow: unknown job");
        return _computeSplit(job.amount, job.feeBps, job.burnBps);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _computeSplit(uint256 amount, uint16 feeBps, uint16 burnBps)
        internal
        pure
        returns (uint256 providerAmount, uint256 burnAmount, uint256 feeAmount)
    {
        uint256 totalFee   = (amount * feeBps) / BPS_DENOM;
        burnAmount         = (totalFee * burnBps) / BPS_DENOM;
        feeAmount          = totalFee - burnAmount;
        providerAmount     = amount - totalFee;
    }

    // -----------------------------------------------------------------------
    // Governance — fee parameters
    // -----------------------------------------------------------------------

    /**
     * @notice Update the protocol fee rate.
     * @dev    Only affects deposits made after this call. Existing jobs retain
     *         the fee rate snapshotted at their deposit time.
     * @param newBps New fee in basis points (e.g. 300 = 3 %). Capped at 10 %.
     */
    function setFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= 1_000, "Escrow: fee > 10%");
        emit FeeBpsUpdated(FEE_BPS, newBps);
        FEE_BPS = newBps;
    }

    /**
     * @notice Update the share of the fee that is burned.
     * @dev    Only affects deposits made after this call.
     * @param newBps Burn share in basis points of the fee (0–10_000).
     */
    function setBurnBps(uint256 newBps) external onlyOwner {
        require(newBps <= BPS_DENOM, "Escrow: burn bps > 100%");
        emit BurnBpsUpdated(BURN_BPS, newBps);
        BURN_BPS = newBps;
    }

    // -----------------------------------------------------------------------
    // Governance — admin addresses
    // -----------------------------------------------------------------------

    /**
     * @notice Update the treasury address.
     * @param _treasury New treasury wallet or contract.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Escrow: zero treasury");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /**
     * @notice Initiate a two-step ownership transfer to `newOwner`.
     * @dev    The new owner must call `acceptOwnership()` to complete the transfer.
     *         This prevents accidental transfer to an address that cannot call
     *         contract functions (e.g. a mistyped address).
     * @param newOwner Address being nominated as the new owner.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Escrow: zero owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /**
     * @notice Complete the ownership transfer initiated by the current owner.
     * @dev    Only callable by the address set in `pendingOwner`.
     */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Escrow: not pending owner");
        address previous = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }
}
