// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ERC-7575 — Multi-Asset ERC-4626 Vaults (share/vault separation)
/// @notice ERC-7540 mandates ERC-7575 support. Its only *new* member for a
/// single-asset vault is `share()`: the rest of the 7575 vault surface
/// (asset, convertTo*, deposit/redeem entry points) is already provided by
/// the inherited ERC-4626.
/// @dev Reference: https://eips.ethereum.org/EIPS/eip-7575
/// ERC-165 id reported by the vault: 0x2f0a18c5.
/// In our vault the share token IS the vault (OZ ERC4626 pattern), so
/// `share()` returns `address(this)` — explicitly allowed by the EIP.
interface IERC7575 {
    /// @notice Address of the share token this vault issues.
    function share() external view returns (address shareTokenAddress);
}
