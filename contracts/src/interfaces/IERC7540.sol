// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ERC-7540 interfaces — Asynchronous ERC-4626 Tokenized Vaults
/// @notice Split per the EIP's method sets, each with its own ERC-165 id so
/// integrators can detect which flows (deposit / redeem) are asynchronous.
/// @dev Reference: https://eips.ethereum.org/EIPS/eip-7540
///
/// Vocabulary (spec):
/// - `owner`      — the address funds (assets or shares) are pulled from at
///                  request time.
/// - `controller` — the address that *owns the request*: it cancels, claims,
///                  and keys all request state. Usually == owner, but the
///                  split enables custody/delegation setups.
/// - operator     — an address a controller has approved to act on its
///                  behalf (per-user delegation, NOT the fund manager).

/// @dev ERC-165 id: 0xe3bc4e65
interface IERC7540Operator {
    /// @notice `controller` granted/revoked `operator` the right to request
    /// and claim on its behalf.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Approve/revoke `operator` for `msg.sender`'s requests.
    function setOperator(address operator, bool approved) external returns (bool success);

    /// @notice Whether `operator` may act on behalf of `controller`.
    function isOperator(address controller, address operator) external view returns (bool status);
}

/// @dev ERC-165 id: 0xce3bbe50 (asynchronous deposit flow)
interface IERC7540Deposit {
    /// @param sender the caller of requestDeposit (owner or its operator)
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Submit `assets` for asynchronous deposit. Assets are pulled
    /// from `owner` immediately (into escrow); shares are minted later at the
    /// epoch's fulfillment price, then claimed via `deposit`/`mint`.
    /// @dev Spec: `owner` MUST be msg.sender or have approved it as operator.
    /// @return requestId here: the epoch id the request joins (fungible
    /// requests — all requests of an epoch share one id and one price).
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Assets of `controller` still pending (not yet fulfilled) under
    /// `requestId`.
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);

    /// @notice Assets of `controller` fulfilled under `requestId` whose
    /// shares are claimable via `deposit`/`mint`.
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    /// @notice Claim overload: spend `assets` of `controller`'s claimable
    /// balance, sending the corresponding shares to `receiver`.
    /// @dev No asset transfer happens here — that happened at request time.
    /// msg.sender MUST be `controller` or its operator.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claim overload denominated in shares.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}

/// @dev ERC-165 id: 0x620ee8e4 (asynchronous redemption flow)
/// @dev No claim overloads are declared here: ERC-4626's own
/// `redeem(shares, receiver, owner)` / `withdraw(assets, receiver, owner)`
/// already carry a third address, reinterpreted as `controller` (spec).
interface IERC7540Redeem {
    /// @param sender the caller of requestRedeem (owner or its operator)
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Submit `shares` for asynchronous redemption. Shares are pulled
    /// from `owner` immediately (into escrow); assets are set aside at the
    /// epoch's fulfillment price, then claimed via `withdraw`/`redeem`.
    /// @dev Spec: authorized by ERC-20 allowance over `owner`'s shares OR
    /// operator approval.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Shares of `controller` still pending under `requestId`.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @notice Shares of `controller` fulfilled under `requestId` whose
    /// assets are claimable via `withdraw`/`redeem`.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}
