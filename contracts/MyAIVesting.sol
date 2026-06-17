// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/finance/VestingWallet.sol";

/**
 * @title MyAIVesting
 * @notice Linear token-vesting wallet for MYAI allocations (team / investor /
 *         treasury locks for the TGE).
 * @dev Thin wrapper over OpenZeppelin VestingWallet 5.0.2 — funds (ETH or any
 *      ERC-20, here MYAI) vest linearly from `startTimestamp` over
 *      `durationSeconds` to the `beneficiary` (the wallet owner). Deploy one
 *      instance per beneficiary; transfer the allocation in after deploy and
 *      call `release(token)` to claim the vested amount. No cliff (OZ 5.0.2
 *      has no VestingWalletCliff); for a cliff, gate with a later start.
 */
contract MyAIVesting is VestingWallet {
    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
    {}
}
