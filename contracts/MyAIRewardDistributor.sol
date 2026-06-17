// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title MyAIRewardDistributor
 * @notice Merkle-based distributor for MYAI rewards / airdrops. The owner
 *         publishes a Merkle root over (index, account, amount) leaves;
 *         recipients claim their allocation by submitting a proof. A bitmap
 *         prevents double-claims, and the owner can sweep any unclaimed
 *         balance after an optional claim deadline.
 *
 * @dev STANDARD Uniswap-style MerkleDistributor pattern (the conventional,
 *      audit-friendly mechanism for one-to-many token distribution). This is a
 *      proposed implementation — confirm it matches the intended reward
 *      mechanism (Merkle claim vs. continuous/pro-rata streaming) before audit.
 *      Leaf = keccak256(abi.encodePacked(index, account, amount)); off-chain
 *      tooling must build the tree with the same encoding and sorted-pair
 *      hashing (OZ MerkleProof).
 */
contract MyAIRewardDistributor is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    bytes32 public merkleRoot;
    uint256 public claimDeadline; // 0 = no deadline (sweep disabled)

    mapping(uint256 => uint256) private claimedBitMap;

    event Claimed(uint256 indexed index, address indexed account, uint256 amount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event ClaimDeadlineUpdated(uint256 deadline);
    event Swept(address indexed to, uint256 amount);

    error AlreadyClaimed();
    error InvalidProof();
    error ClaimWindowClosed();
    error SweepNotAllowedYet();

    constructor(address _token, bytes32 _merkleRoot, uint256 _claimDeadline) Ownable(msg.sender) {
        require(_token != address(0), "Token zero");
        token = IERC20(_token);
        merkleRoot = _merkleRoot;
        claimDeadline = _claimDeadline;
    }

    function isClaimed(uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 mask = (1 << bitIndex);
        return claimedBitMap[wordIndex] & mask == mask;
    }

    function _setClaimed(uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[wordIndex] |= (1 << bitIndex);
    }

    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external {
        if (claimDeadline != 0 && block.timestamp > claimDeadline) revert ClaimWindowClosed();
        if (isClaimed(index)) revert AlreadyClaimed();

        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) revert InvalidProof();

        _setClaimed(index);
        token.safeTransfer(account, amount);
        emit Claimed(index, account, amount);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────
    function setMerkleRoot(bytes32 _root) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, _root);
        merkleRoot = _root;
    }

    function setClaimDeadline(uint256 _deadline) external onlyOwner {
        claimDeadline = _deadline;
        emit ClaimDeadlineUpdated(_deadline);
    }

    /// @notice Recover unclaimed tokens after the claim window closes.
    function sweep(address to) external onlyOwner {
        if (claimDeadline == 0 || block.timestamp <= claimDeadline) revert SweepNotAllowedYet();
        require(to != address(0), "Zero address");
        uint256 bal = token.balanceOf(address(this));
        token.safeTransfer(to, bal);
        emit Swept(to, bal);
    }
}
