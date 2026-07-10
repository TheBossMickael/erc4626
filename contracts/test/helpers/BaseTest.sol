// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RWAVault} from "../../src/RWAVault.sol";
import {Escrow} from "../../src/Escrow.sol";
import {NAVOracle} from "../../src/NAVOracle.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {TBillToken} from "../../src/mocks/TBillToken.sol";

/// @notice Shared deployment, actors and lifecycle helpers for every suite.
/// @dev The deployer (this contract) holds DEFAULT_ADMIN_ROLE on the vault
/// and owns the oracle; `manager` holds MANAGER_ROLE only. Admin and manager
/// are kept on distinct addresses on purpose, so the access-control matrix
/// can prove the role separation of D10 (an admin is NOT a manager).
abstract contract BaseTest is Test {
    /// @dev Share decimals == asset decimals == 6 (OZ offset 0, TBILL matches USDC).
    uint256 internal constant ONE_SHARE = 1e6;
    uint256 internal constant RATE_BPS = 450; // 4.5% APR — demo default
    uint256 internal constant TIME_SCALE = 1440; // 1 real minute = 1 simulated day

    MockUSDC internal usdc;
    NAVOracle internal oracle;
    TBillToken internal tbill;
    RWAVault internal vault;
    Escrow internal escrow;

    address internal manager;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal eve; // used as an ERC-7540 operator in several suites

    function setUp() public virtual {
        manager = makeAddr("manager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        eve = makeAddr("eve");

        usdc = new MockUSDC();
        oracle = new NAVOracle(RATE_BPS, TIME_SCALE);
        tbill = new TBillToken(oracle, usdc);
        vault = new RWAVault(usdc, tbill, oracle, manager);
        escrow = vault.escrow();
    }

    // ------------------------------------------------------------------
    // Request helpers
    // ------------------------------------------------------------------

    function _mintAndApprove(address user, uint256 assets) internal {
        usdc.mint(user, assets);
        vm.prank(user);
        usdc.approve(address(vault), assets);
    }

    function _requestDeposit(address user, uint256 assets) internal returns (uint256 requestId) {
        _mintAndApprove(user, assets);
        vm.prank(user);
        requestId = vault.requestDeposit(assets, user, user);
    }

    function _requestRedeem(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = vault.requestRedeem(shares, user, user);
    }

    // ------------------------------------------------------------------
    // Epoch cycle helpers (manager)
    // ------------------------------------------------------------------

    function _close() internal returns (uint256 closedId) {
        vm.prank(manager);
        closedId = vault.closeEpoch();
    }

    function _fulfill() internal returns (uint256 fulfilledId) {
        vm.prank(manager);
        fulfilledId = vault.fulfillEpoch();
    }

    function _closeAndFulfill() internal {
        _close();
        _fulfill();
    }

    function _invest(uint256 assets) internal {
        vm.prank(manager);
        vault.invest(assets);
    }

    function _divest(uint256 tbillAmount) internal {
        vm.prank(manager);
        vault.divest(tbillAmount);
    }

    /// @dev Bootstrap liquidity: `user` deposits through a full epoch and
    /// claims; the vault ends with `assets` cash and the matching supply.
    function _seedVault(address user, uint256 assets) internal returns (uint256 sharesOut) {
        _requestDeposit(user, assets);
        _closeAndFulfill();
        vm.prank(user);
        sharesOut = vault.deposit(assets, user);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @dev Price of one whole share in asset terms (6-decimals USDC).
    function _pps() internal view returns (uint256) {
        return vault.convertToAssets(ONE_SHARE);
    }

    function _epoch(uint256 id) internal view returns (RWAVault.Epoch memory e) {
        (e.totalDepositAssets, e.totalRedeemShares, e.sharesMinted, e.assetsSetAside, e.cutoffAt, e.fulfilledAt) =
            vault.epochs(id);
    }
}
