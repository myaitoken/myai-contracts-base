// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title MyAITimelock
 * @notice Execution timelock for MyAi governance (default 48h delay), so passed
 *         proposals queue for a mandatory delay before they can run.
 * @dev Thin wrapper over OpenZeppelin TimelockController 5.0.2.
 *      - proposers: the MyAIGovernance contract (queues operations)
 *      - executors: governance or address(0) (open execution after delay)
 *      - admin: pass address(0) to renounce the admin role at deploy
 *        (recommended for trust-minimization), or a setup multisig that
 *        renounces after wiring roles.
 */
contract MyAITimelock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
