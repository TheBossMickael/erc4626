// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {NAVOracle} from "../src/NAVOracle.sol";
import {RWAVault} from "../src/RWAVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {TBillToken} from "../src/mocks/TBillToken.sol";

/// @title Deploy — full demo stack, one broadcaster key
/// @notice Deploys MockUSDC → NAVOracle → TBillToken → RWAVault (which
/// deploys its own Escrow). Demo key management: the single broadcaster EOA
/// ends up holding DEFAULT_ADMIN_ROLE + MANAGER_ROLE on the vault and the
/// oracle's ownership — threat-model residual risk 4, accepted for the demo.
/// A production deployment would split those onto distinct keys (D10).
///
/// @dev No key material lives in this file: the broadcaster is whatever the
/// CLI supplies (`--private-key "$PRIVATE_KEY"` from the environment, or a
/// keystore via `--account`). Nothing here reads env vars either, so the
/// script cannot leak a secret into broadcast artifacts.
contract Deploy is Script {
    /// @dev 4.50% APR — T-Bill-grade yield (design decisions D3/D8).
    uint256 internal constant INITIAL_RATE_BPS = 450;

    /// @dev 1 real minute = 1 simulated day (1440 min/day): NAV accrual is
    /// visible during a live demo instead of being a flat line (D8).
    uint256 internal constant INITIAL_TIME_SCALE = 1440;

    function run() external returns (MockUSDC usdc, NAVOracle oracle, TBillToken tbill, RWAVault vault) {
        vm.startBroadcast();

        // The actual broadcaster address, however the CLI provided the key —
        // needed as an explicit constructor argument for the manager below.
        (, address deployer,) = vm.readCallers();

        usdc = new MockUSDC();
        oracle = new NAVOracle(INITIAL_RATE_BPS, INITIAL_TIME_SCALE); // owner = deployer (Ownable)
        tbill = new TBillToken(oracle, usdc);
        // msg.sender of this creation (the deployer) gets DEFAULT_ADMIN_ROLE;
        // the same EOA is passed as manager — single demo operator key.
        vault = new RWAVault(usdc, tbill, oracle, deployer);

        vm.stopBroadcast();

        console2.log("deployer (admin + manager + oracle owner):", deployer);
        console2.log("MockUSDC:   ", address(usdc));
        console2.log("NAVOracle:  ", address(oracle));
        console2.log("TBillToken: ", address(tbill));
        console2.log("RWAVault:   ", address(vault));
        // Deployed by the vault's constructor — a nested creation, so
        // `forge script --verify` will NOT auto-verify it (see the manual
        // `forge verify-contract` step in the deployment runbook).
        console2.log("Escrow:     ", address(vault.escrow()));
    }
}
