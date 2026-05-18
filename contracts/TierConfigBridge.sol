// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title TierConfigBridge
 * @notice On-chain mirror of MyAi's per-tier emission/cap dial.
 *         Only MyAIGovernance can write. Anyone can read.
 *
 * @dev Anti-sybil v3 piece B (#8966). The coordinator's
 *      api/services/governance_listener.py polls MyAIGovernance for
 *      proposals that target this contract; when a proposal hits the
 *      EXECUTED state, the listener mirrors the new config back into the
 *      coordinator's tier_config table.
 *
 *      All writes are gated by onlyGovernance -- there is no admin
 *      bypass, no owner-style escape hatch. This is intentional: the
 *      whole point of v3-B is to remove single-secret tier config writes
 *      from production.
 */
contract TierConfigBridge {
    struct TierCfg {
        int128  maxAgentsPerWallet;
        int128  dailyEarningsCapPerWalletMyai;
        int128  dailyEmissionCapMyai;
        uint64  multiplierAttestedBps;
        uint64  multiplierUnattestedBps;
        uint64  slashCapPctBps;
    }

    string[4] public TIERS = ["consumer", "mobile", "datacenter", "browser"];

    address public immutable governance;

    mapping(string => TierCfg) private _cfg;
    mapping(string => bool) public initialised;

    event TierConfigUpdated(
        string  indexed tier,
        int128  maxAgentsPerWallet,
        int128  dailyEarningsCapPerWalletMyai,
        int128  dailyEmissionCapMyai,
        uint64  multiplierAttestedBps,
        uint64  multiplierUnattestedBps,
        uint64  slashCapPctBps
    );

    error NotGovernance(address caller);
    error UnknownTier(string tier);
    error ZeroGovernance();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance(msg.sender);
        _;
    }

    constructor(address _governance) {
        if (_governance == address(0)) revert ZeroGovernance();
        governance = _governance;
    }

    function setTier(string calldata tier, TierCfg calldata cfg) external onlyGovernance {
        if (!_isKnownTier(tier)) revert UnknownTier(tier);
        _cfg[tier] = cfg;
        initialised[tier] = true;
        emit TierConfigUpdated(
            tier,
            cfg.maxAgentsPerWallet,
            cfg.dailyEarningsCapPerWalletMyai,
            cfg.dailyEmissionCapMyai,
            cfg.multiplierAttestedBps,
            cfg.multiplierUnattestedBps,
            cfg.slashCapPctBps
        );
    }

    function getTier(string calldata tier) external view returns (TierCfg memory) {
        if (!_isKnownTier(tier)) revert UnknownTier(tier);
        return _cfg[tier];
    }

    function _isKnownTier(string memory tier) internal view returns (bool) {
        bytes32 h = keccak256(bytes(tier));
        for (uint256 i = 0; i < TIERS.length; i++) {
            if (keccak256(bytes(TIERS[i])) == h) return true;
        }
        return false;
    }
}
