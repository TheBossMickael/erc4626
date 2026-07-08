// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Escrow — vault-only custody of pending and claimable funds
/// @notice Holds everything that is *not* the fund's: pending deposit assets,
/// pending redeem shares, and post-fulfillment claimables (minted shares,
/// payout assets). Deliberately dumb: all logic lives in the vault.
///
/// @dev Why a separate contract instead of tracked balances inside the vault
/// (design decision D9): the vault's `totalAssets()` is then *physically*
/// unable to count pending money, eliminating by construction the bug class
/// where depositors' own pending cash inflates the NAV they will pay
/// (threat T2). Segregation is the security property; no exclusion
/// arithmetic exists to get wrong.
///
/// Deployed by the vault's constructor, so `vault` is bound once and has no
/// setter, no owner, no upgrade path.
contract Escrow {
    using SafeERC20 for IERC20;

    address public immutable vault;

    error NotVault();

    constructor() {
        vault = msg.sender;
    }

    /// @notice Move escrowed tokens. Inbound transfers need no function —
    /// the vault transfers directly to this address.
    function transferTo(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        token.safeTransfer(to, amount);
    }
}
