// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SwarmCore
/// @notice Fixed-supply ERC-20: one billion SWARMCOR with 18 decimals.
/// @dev The immediate deployer receives the entire supply. No external mint, burn, or admin functions exist.
contract SwarmCore is ERC20 {
    /// @notice The one-time issuance, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("SwarmCore", "SWARMCOR") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
