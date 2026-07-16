// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Handler} from "./Handler.sol";
import {RWAVault} from "../../src/RWAVault.sol";

/// @notice Fuzzed invariant campaign for I1–I9 (docs/invariants-and-testing.md).
///
/// Where each invariant is checked:
///  - I1 (epoch price uniqueness)  — pairwise assertion at every fulfillment (Handler)
///  - I2 (conservation per epoch)  — at every fulfillment (Handler) + re-checked below
///  - I3 (NAV continuity)          — at every fulfillment (Handler) + unit fuzz in test/unit
///  - I4 (escrow solvency, EXACT)  — invariant_I4 below (ghosts track dust on BOTH sides)
///  - I5 (supply discipline)       — asserted around every Handler action
///  - I6 (pending isolation)       — asserted around every request/cancel/claim (Handler)
///  - I7 (no double-claim)         — invariant_I7 below (lifetime paid vs entitled)
///  - I8 (access control)          — unit matrix (test/unit/AccessControlMatrix.t.sol)
///  - I9 (state-machine sanity)    — invariant_I9 below + unit tests on illegal transitions
///
/// The campaign runs with fail-on-revert: the Handler only performs legal
/// actions, so ANY revert reaching the runner is a finding in itself.
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RWAVaultInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(vault, usdc, tbill, oracle, manager, address(this));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = Handler.requestDeposit.selector;
        selectors[1] = Handler.requestRedeem.selector;
        selectors[2] = Handler.cancelDeposit.selector;
        selectors[3] = Handler.cancelRedeem.selector;
        selectors[4] = Handler.claimDeposit.selector;
        selectors[5] = Handler.claimMint.selector;
        selectors[6] = Handler.claimWithdraw.selector;
        selectors[7] = Handler.claimRedeem.selector;
        selectors[8] = Handler.closeEpoch.selector;
        selectors[9] = Handler.fulfillEpoch.selector;
        selectors[10] = Handler.warpTime.selector;
        selectors[11] = Handler.shockNAV.selector;
        selectors[12] = Handler.invest.selector;
        selectors[13] = Handler.divest.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice I4 — the escrow holds EXACTLY what is owed, in both
    /// denominations: outstanding pendings + unclaimed entitlements +
    /// accumulated rounding dust (dust exists on BOTH sides). Equality, not
    /// >=: drift in either direction signals a leak or a double-count.
    function invariant_I4_escrowSolvencyExact() public view {
        assertEq(
            usdc.balanceOf(address(escrow)),
            handler.ghostPendingDepositAssets() + handler.ghostUnclaimedRedeemAssets()
                + handler.ghostRedeemAssetDust(),
            "I4: escrow USDC != pendings + unclaimed payouts + dust"
        );
        assertEq(
            vault.balanceOf(address(escrow)),
            handler.ghostPendingRedeemShares() + handler.ghostUnclaimedDepositShares()
                + handler.ghostDepositShareDust(),
            "I4: escrow shares != pendings + unclaimed shares + dust"
        );
    }

    /// @notice I7 — lifetime claims never exceed lifetime entitlements, per
    /// controller and per denomination, across any interleaving of rolls,
    /// partial claims and new requests.
    function invariant_I7_noDoubleClaim() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertLe(handler.ghostPaidShares(actor), handler.ghostEntitledShares(actor), "I7: over-claimed shares");
            assertLe(handler.ghostPaidAssets(actor), handler.ghostEntitledAssets(actor), "I7: over-claimed assets");
        }
    }

    /// @notice I9 — exactly one OPEN epoch, at most one CLOSED epoch, older
    /// epochs all FULFILLED and their recorded batch results immutable
    /// (compared against the snapshot taken at fulfillment time). I2 is
    /// re-asserted on the stored snapshots.
    function invariant_I9_epochStateMachine() public view {
        uint256 open = vault.currentEpochId();
        RWAVault.Epoch memory e = _epoch(open);
        assertEq(e.cutoffAt, 0, "I9: the OPEN epoch has a cut-off");
        assertEq(e.fulfilledAt, 0, "I9: the OPEN epoch is fulfilled");

        for (uint256 id = 1; id < open; ++id) {
            e = _epoch(id);
            assertTrue(e.cutoffAt != 0, "I9: a past epoch was never closed");
            if (id < open - 1) {
                assertTrue(e.fulfilledAt != 0, "I9: more than one epoch awaiting settlement");
            }
            if (e.fulfilledAt != 0) {
                Handler.GhostEpoch memory g = handler.ghostEpoch(id);
                assertTrue(g.fulfilled, "ghost accounting missed a fulfillment");
                assertEq(e.totalDepositAssets, g.totalDepositAssets, "I9: totalDepositAssets mutated");
                assertEq(e.totalRedeemShares, g.totalRedeemShares, "I9: totalRedeemShares mutated");
                assertEq(e.sharesMinted, g.sharesMinted, "I9: sharesMinted mutated");
                assertEq(e.assetsSetAside, g.assetsSetAside, "I9: assetsSetAside mutated");
                assertLe(g.sumEntitledShares, g.sharesMinted, "I2: deposit conservation");
                assertLe(g.sumEntitledAssets, g.assetsSetAside, "I2: redeem conservation");
            }
        }
    }
}
