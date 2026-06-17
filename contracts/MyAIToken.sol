// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title MyAIToken
 * @notice The MYAI ERC-20 token (Base mainnet 0xAfF22CC20434ce43B3ea10efe10e9360390D327c).
 * @dev Reconstructed from the Basescan exact-match verified source (compiler
 *      v0.8.20, optimizer off / 200 runs, paris). Fixed supply of 1,000,000,000
 *      MYAI (18 decimals) minted to the deployer at construction. No mint, no
 *      owner, no pause — burn / burnFrom come from OZ ERC20Burnable.
 *
 *      Committed for version control + test coverage (board card 9400); the
 *      deployed bytecode was previously not in any repo.
 */
contract MyAIToken is ERC20, ERC20Burnable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("MyAI", "MYAI") {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}
