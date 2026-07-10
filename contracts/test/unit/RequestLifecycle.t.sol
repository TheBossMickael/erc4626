// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {IERC7540Deposit, IERC7540Redeem} from "../../src/interfaces/IERC7540.sol";

/// @notice Request lifecycle, both directions: submission, same-epoch
/// aggregation, controller semantics, the CLOSED-unfulfilled window (slot
/// busy + binding orders), auto-roll at the next touchpoint, cancellation
/// (D7), and the pending/claimable view semantics.
contract RequestLifecycleTest is BaseTest {
    // ==================================================================
    // requestDeposit
    // ==================================================================

    function test_requestDeposit_movesAssetsToEscrowAndRecordsPending() public {
        _mintAndApprove(alice, 1_000e6);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC7540Deposit.DepositRequest(alice, alice, 1, alice, 1_000e6);
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(1_000e6, alice, alice);

        assertEq(requestId, 1, "requestId == the OPEN epoch id");
        assertEq(usdc.balanceOf(address(escrow)), 1_000e6, "assets custodied in escrow");
        assertEq(usdc.balanceOf(address(vault)), 0, "no assets reach the vault before settlement");
        assertEq(vault.totalAssets(), 0, "pending cash physically outside totalAssets (T2)");
        assertEq(vault.pendingDepositRequest(1, alice), 1_000e6);
        assertEq(_epoch(1).totalDepositAssets, 1_000e6);
    }

    function test_requestDeposit_aggregatesWithinOpenEpoch() public {
        _requestDeposit(alice, 300e6);
        _requestDeposit(alice, 200e6);
        _requestDeposit(bob, 500e6);

        assertEq(vault.pendingDepositRequest(1, alice), 500e6, "same-epoch requests aggregate per controller");
        assertEq(vault.pendingDepositRequest(1, bob), 500e6);
        assertEq(_epoch(1).totalDepositAssets, 1_000e6, "epoch total aggregates all controllers");
    }

    function test_requestDeposit_zeroReverts() public {
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.requestDeposit(0, alice, alice);
    }

    function test_requestDeposit_controllerOwnsTheRequest() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, bob, alice); // alice funds, bob controls

        assertEq(vault.pendingDepositRequest(1, bob), 1_000e6, "request keyed on the controller");
        assertEq(vault.pendingDepositRequest(1, alice), 0);

        // the controller cancels; the refund goes to the CONTROLLER, not to
        // the original funds source (documented D7 semantics: `owner` is
        // deliberately not stored)
        vm.prank(bob);
        uint256 refunded = vault.cancelDepositRequest(bob);
        assertEq(refunded, 1_000e6);
        assertEq(usdc.balanceOf(bob), 1_000e6, "refund reaches the controller");
        assertEq(usdc.balanceOf(alice), 0, "funds source deliberately not refunded");
    }

    // ==================================================================
    // The CLOSED-unfulfilled window (D4): slot busy, orders binding
    // ==================================================================

    function test_requestDeposit_slotBusyDuringClosedWindow_reverts() public {
        _requestDeposit(alice, 1_000e6);
        _close(); // epoch 1 CLOSED, not fulfilled: alice's slot is busy

        _mintAndApprove(alice, 500e6);
        vm.expectRevert(RWAVault.PendingRequestUnfulfilled.selector);
        vm.prank(alice);
        vault.requestDeposit(500e6, alice, alice);
    }

    function test_cancelDeposit_duringClosedWindow_reverts() public {
        _requestDeposit(alice, 1_000e6);
        _close(); // cut-off: the order is now binding (T4 mitigation)

        vm.expectRevert(RWAVault.RequestNotCancelable.selector);
        vm.prank(alice);
        vault.cancelDepositRequest(alice);
    }

    function test_requestDeposit_freshControllerJoinsNextEpochDuringClosedWindow() public {
        _requestDeposit(alice, 1_000e6);
        _close();

        // bob has no busy slot: his request simply joins the new OPEN epoch
        uint256 id = _requestDeposit(bob, 700e6);
        assertEq(id, 2);
        assertEq(vault.pendingDepositRequest(2, bob), 700e6);
        assertEq(_epoch(1).totalDepositAssets, 1_000e6, "closed epoch totals frozen");

        // settling epoch 1 leaves epoch 2's pendings untouched
        _fulfill();
        assertEq(vault.pendingDepositRequest(2, bob), 700e6, "epoch-2 pending unaffected by epoch-1 settlement");
    }

    function test_requestDeposit_autoRollsFulfilledSlotThenJoinsOpenEpoch() public {
        _requestDeposit(alice, 1_000e6);
        _closeAndFulfill(); // epoch 1 settles at par: 1_000e6 shares

        _mintAndApprove(alice, 400e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit RWAVault.DepositClaimable(alice, 1, 1_000e6, 1_000e6);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(400e6, alice, alice);

        assertEq(id, 2, "new request joins the OPEN epoch");
        (uint256 claimAssets, uint256 claimShares) = vault.claimableDeposit(alice);
        assertEq(claimAssets, 1_000e6, "epoch-1 entitlement rolled into the ledger");
        assertEq(claimShares, 1_000e6, "first epoch settles 1:1");
        assertEq(vault.pendingDepositRequest(2, alice), 400e6, "slot reused for the new epoch");
    }

    // ==================================================================
    // Pending / claimable view semantics
    // ==================================================================

    function test_pendingDepositRequest_matchesRequestIdExactly() public {
        _requestDeposit(alice, 1_000e6);
        assertEq(vault.pendingDepositRequest(1, alice), 1_000e6);
        assertEq(vault.pendingDepositRequest(2, alice), 0, "wrong requestId reads zero");
        assertEq(vault.pendingDepositRequest(0, alice), 0);

        _close();
        // CLOSED but not fulfilled: still pending per spec (binding != claimable)
        assertEq(vault.pendingDepositRequest(1, alice), 1_000e6, "binding order is still pending");
        assertEq(vault.maxDeposit(alice), 0, "nothing claimable during the CLOSED window");

        _fulfill();
        // fulfilled: pending reads zero with NO touchpoint (view-simulated roll)
        assertEq(vault.pendingDepositRequest(1, alice), 0, "fulfilled request no longer pending");
        assertEq(vault.maxDeposit(alice), 1_000e6, "claimable through max* before any touchpoint");
        assertEq(vault.claimableDepositRequest(1, alice), 1_000e6);
        assertEq(vault.claimableDepositRequest(42, alice), 1_000e6, "requestId ignored: fungible claim ledger");
    }

    // ==================================================================
    // requestRedeem (mirror)
    // ==================================================================

    function test_requestRedeem_movesSharesToEscrow_supplyUnchanged() public {
        uint256 shares = _seedVault(alice, 1_000e6);
        uint256 supplyBefore = vault.totalSupply();
        uint256 ppsBefore = _pps();

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC7540Redeem.RedeemRequest(alice, alice, 2, alice, 400e6);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(400e6, alice, alice);

        assertEq(id, 2, "epoch 2 is open after the seed cycle");
        assertEq(vault.balanceOf(address(escrow)), 400e6, "shares custodied in escrow, un-burned");
        assertEq(vault.balanceOf(alice), shares - 400e6);
        assertEq(vault.totalSupply(), supplyBefore, "I5: no burn at request time");
        assertEq(_pps(), ppsBefore, "I6: a request never moves the price");
        assertEq(vault.pendingRedeemRequest(2, alice), 400e6);
        assertEq(_epoch(2).totalRedeemShares, 400e6);
    }

    function test_requestRedeem_aggregatesWithinOpenEpoch() public {
        _seedVault(alice, 1_000e6);
        _requestRedeem(alice, 100e6);
        _requestRedeem(alice, 150e6);

        assertEq(vault.pendingRedeemRequest(2, alice), 250e6);
        assertEq(_epoch(2).totalRedeemShares, 250e6);
    }

    function test_requestRedeem_zeroReverts() public {
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.requestRedeem(0, alice, alice);
    }

    function test_requestRedeem_slotBusyDuringClosedWindow_reverts() public {
        _seedVault(alice, 1_000e6);
        _requestRedeem(alice, 100e6);
        _close();

        vm.expectRevert(RWAVault.PendingRequestUnfulfilled.selector);
        vm.prank(alice);
        vault.requestRedeem(100e6, alice, alice);
    }

    function test_requestRedeem_autoRollsFulfilledSlot() public {
        _seedVault(alice, 1_000e6);
        _requestRedeem(alice, 400e6);
        _closeAndFulfill(); // cash-only vault: epoch 2 settles at par too

        vm.expectEmit(true, true, false, true, address(vault));
        emit RWAVault.RedeemClaimable(alice, 2, 400e6, 400e6);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(100e6, alice, alice);

        assertEq(id, 3);
        (uint256 claimAssets, uint256 claimShares) = vault.claimableRedeem(alice);
        assertEq(claimShares, 400e6, "epoch-2 shares rolled into the ledger");
        assertEq(claimAssets, 400e6, "par NAV: 1 share pays 1 asset");
        assertEq(vault.pendingRedeemRequest(3, alice), 100e6);
    }

    // ==================================================================
    // Cancellation (D7): full refund, pre-cut-off only
    // ==================================================================

    function test_cancelDepositRequest_fullRefund() public {
        _requestDeposit(alice, 1_000e6);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RWAVault.DepositRequestCanceled(alice, 1, 1_000e6);
        vm.prank(alice);
        uint256 refunded = vault.cancelDepositRequest(alice);

        assertEq(refunded, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(vault.pendingDepositRequest(1, alice), 0);
        assertEq(_epoch(1).totalDepositAssets, 0, "epoch total decremented");

        // the freed slot is reusable within the same epoch
        _requestDeposit(alice, 250e6);
        assertEq(vault.pendingDepositRequest(1, alice), 250e6);
    }

    function test_cancelDepositRequest_noPending_reverts() public {
        vm.expectRevert(RWAVault.NoPendingRequest.selector);
        vm.prank(alice);
        vault.cancelDepositRequest(alice);
    }

    function test_cancelDepositRequest_afterFulfillment_revertsNoPending() public {
        _requestDeposit(alice, 1_000e6);
        _closeAndFulfill();

        // a fulfilled pending is claimable, not cancelable: the cancel path
        // rolls the slot first and then finds nothing pending
        vm.expectRevert(RWAVault.NoPendingRequest.selector);
        vm.prank(alice);
        vault.cancelDepositRequest(alice);
    }

    function test_cancelRedeemRequest_fullRefund() public {
        uint256 shares = _seedVault(alice, 1_000e6);
        _requestRedeem(alice, 400e6);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RWAVault.RedeemRequestCanceled(alice, 2, 400e6);
        vm.prank(alice);
        uint256 refunded = vault.cancelRedeemRequest(alice);

        assertEq(refunded, 400e6);
        assertEq(vault.balanceOf(alice), shares, "shares returned in full");
        assertEq(vault.balanceOf(address(escrow)), 0);
        assertEq(_epoch(2).totalRedeemShares, 0);
    }

    function test_cancelRedeemRequest_duringClosedWindow_reverts() public {
        _seedVault(alice, 1_000e6);
        _requestRedeem(alice, 400e6);
        _close();

        vm.expectRevert(RWAVault.RequestNotCancelable.selector);
        vm.prank(alice);
        vault.cancelRedeemRequest(alice);
    }

    function test_cancelRedeemRequest_noPending_reverts() public {
        vm.expectRevert(RWAVault.NoPendingRequest.selector);
        vm.prank(alice);
        vault.cancelRedeemRequest(alice);
    }

    // ==================================================================
    // I6 spot check (full campaign in test/invariant)
    // ==================================================================

    function test_requestsAndCancels_neverMoveThePrice() public {
        _seedVault(alice, 10_000e6);
        uint256 pps = _pps();

        _requestDeposit(bob, 5_000e6);
        assertEq(_pps(), pps, "I6: requestDeposit moved the price");
        _requestRedeem(alice, 2_000e6);
        assertEq(_pps(), pps, "I6: requestRedeem moved the price");
        vm.prank(bob);
        vault.cancelDepositRequest(bob);
        assertEq(_pps(), pps, "I6: cancelDeposit moved the price");
        vm.prank(alice);
        vault.cancelRedeemRequest(alice);
        assertEq(_pps(), pps, "I6: cancelRedeem moved the price");
    }
}
