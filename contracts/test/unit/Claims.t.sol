// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The claim surface: the four reinterpreted ERC-4626 entry points,
/// partial vs full claims, the T3 rounding policy (payouts floor,
/// ledger consumption ceils, full claims take the exact pair so nothing is
/// ever stranded), multi-epoch aggregation of the fungible claim ledger,
/// max*/preview* semantics.
contract ClaimsTest is BaseTest {
    function setUp() public override {
        super.setUp();
        // non-trivial NAV: seed, invest, accrue — later epochs settle away
        // from par so the rounding paths are actually exercised
        _seedVault(carol, 100_000e6);
        _invest(80_000e6);
        vm.warp(block.timestamp + 1 hours); // ~60 simulated days: price ≈ 1.0074
    }

    // ------------------------------------------------------------------
    // Local pipelines
    // ------------------------------------------------------------------

    /// @dev Runs `user` through a full deposit epoch; returns the claimable pair.
    function _fulfilledDeposit(address user, uint256 assets) internal returns (uint256 a, uint256 s) {
        _requestDeposit(user, assets);
        _closeAndFulfill();
        a = vault.maxDeposit(user);
        s = vault.maxMint(user);
    }

    /// @dev Gives `user` claimed shares, then runs a redeem epoch over `shares`.
    function _fulfilledRedeem(address user, uint256 depositAssets, uint256 shares)
        internal
        returns (uint256 a, uint256 s)
    {
        (, uint256 owned) = _fulfilledDeposit(user, depositAssets);
        vm.prank(user);
        vault.mint(owned, user, user);
        vm.warp(block.timestamp + 30 minutes); // decorrelate the two epoch prices
        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        _closeAndFulfill();
        a = vault.maxWithdraw(user);
        s = vault.maxRedeem(user);
    }

    // ==================================================================
    // deposit / mint — deposit-side claims
    // ==================================================================

    function test_deposit_fullClaim_takesExactPair() public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 10_000e6);
        assertEq(a, 10_000e6);
        assertEq(s, _epoch(2).sharesMinted, "single requester earns the whole batch");

        // spec: the Deposit event is keyed on the CONTROLLER, not msg.sender
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(alice, alice, a, s);
        vm.prank(alice);
        uint256 sharesOut = vault.deposit(a, alice); // 2-arg form: controller = msg.sender

        assertEq(sharesOut, s);
        assertEq(vault.balanceOf(alice), s);
        (uint256 remA, uint256 remS) = vault.claimableDeposit(alice);
        assertEq(remA, 0);
        assertEq(remS, 0);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_deposit_partialClaim_floorsSharesOut_thenRestStrandsNothing() public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 10_000e6);

        uint256 x = a / 3;
        vm.prank(alice);
        uint256 out1 = vault.deposit(x, alice, alice);
        assertEq(out1, Math.mulDiv(x, s, a), "partial payout rounds down (T3)");

        (uint256 remA, uint256 remS) = vault.claimableDeposit(alice);
        assertEq(remA, a - x, "assets consumed exactly");
        assertEq(remS, s - out1);

        // the full claim of the remainder takes the exact pair: zero stranding
        vm.prank(alice);
        uint256 out2 = vault.deposit(a - x, alice, alice);
        assertEq(out1 + out2, s, "partial claims recover the exact entitlement");
        assertEq(vault.maxMint(alice), 0);
    }

    function test_mint_partialClaim_ceilsAssetsConsumed() public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 10_000e6);

        uint256 y = s / 3;
        vm.prank(alice);
        uint256 consumed = vault.mint(y, alice, alice);

        assertEq(consumed, Math.mulDiv(y, a, s, Math.Rounding.Ceil), "ledger consumption rounds up (T3)");
        assertEq(vault.balanceOf(alice), y);
        (uint256 remA, uint256 remS) = vault.claimableDeposit(alice);
        assertEq(remA, a - consumed);
        assertEq(remS, s - y);

        vm.prank(alice);
        vault.mint(s - y, alice, alice); // full remainder
        assertEq(vault.balanceOf(alice), s);
        assertEq(vault.maxDeposit(alice), 0, "nothing stranded");
    }

    function test_claim_toThirdPartyReceiver() public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(a, bob, alice); // receiver = bob

        assertEq(vault.balanceOf(bob), s, "shares delivered to the chosen receiver");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.maxDeposit(alice), 0, "controller's ledger debited");
    }

    // ==================================================================
    // withdraw / redeem — redeem-side claims
    // ==================================================================

    function test_withdraw_fullClaim_takesExactPair() public {
        (uint256 a, uint256 s) = _fulfilledRedeem(alice, 10_000e6, 4_000e6);
        assertEq(s, 4_000e6);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, a, s);
        vm.prank(alice);
        uint256 sharesConsumed = vault.withdraw(a, alice, alice);

        assertEq(sharesConsumed, s);
        assertEq(usdc.balanceOf(alice) - balBefore, a);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_withdraw_partialClaim_ceilsSharesConsumed() public {
        (uint256 a, uint256 s) = _fulfilledRedeem(alice, 10_000e6, 4_000e6);

        uint256 x = a / 7;
        vm.prank(alice);
        uint256 consumed = vault.withdraw(x, alice, alice);
        assertEq(consumed, Math.mulDiv(x, s, a, Math.Rounding.Ceil), "shares consumed round up (T3)");

        (uint256 remA, uint256 remS) = vault.claimableRedeem(alice);
        assertEq(remA, a - x);
        assertEq(remS, s - consumed);
    }

    function test_redeem_partialClaim_floorsAssetsOut_thenRestStrandsNothing() public {
        (uint256 a, uint256 s) = _fulfilledRedeem(alice, 10_000e6, 4_000e6);

        uint256 y = s / 7;
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out1 = vault.redeem(y, alice, alice);
        assertEq(out1, Math.mulDiv(y, a, s), "payout rounds down (T3)");

        vm.prank(alice);
        uint256 out2 = vault.redeem(s - y, alice, alice);
        assertEq(out1 + out2, a, "no assets stranded across partial claims");
        assertEq(usdc.balanceOf(alice) - balBefore, a);
        assertEq(vault.maxRedeem(alice), 0);
    }

    // ==================================================================
    // Guards
    // ==================================================================

    function test_claims_beyondClaimable_revert() public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(RWAVault.ExceedsClaimable.selector, a + 1, a));
        vm.prank(alice);
        vault.deposit(a + 1, alice, alice);

        vm.expectRevert(abi.encodeWithSelector(RWAVault.ExceedsClaimable.selector, s + 1, s));
        vm.prank(alice);
        vault.mint(s + 1, alice, alice);

        // no redeem-side claimables at all
        vm.expectRevert(abi.encodeWithSelector(RWAVault.ExceedsClaimable.selector, 1, 0));
        vm.prank(alice);
        vault.withdraw(1, alice, alice);

        vm.expectRevert(abi.encodeWithSelector(RWAVault.ExceedsClaimable.selector, 1, 0));
        vm.prank(alice);
        vault.redeem(1, alice, alice);
    }

    function test_claims_zeroAmount_revert() public {
        _fulfilledDeposit(alice, 1_000e6);

        vm.startPrank(alice);
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vault.deposit(0, alice, alice);
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vault.mint(0, alice, alice);
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vault.redeem(0, alice, alice);
        vm.stopPrank();
    }

    function test_previewFunctions_revert() public {
        vm.expectRevert(RWAVault.PreviewNotSupported.selector);
        vault.previewDeposit(1);
        vm.expectRevert(RWAVault.PreviewNotSupported.selector);
        vault.previewMint(1);
        vm.expectRevert(RWAVault.PreviewNotSupported.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(RWAVault.PreviewNotSupported.selector);
        vault.previewRedeem(1);
    }

    // ==================================================================
    // Multi-epoch aggregation (fungible claim ledger)
    // ==================================================================

    function test_multiEpochAggregation_depositSide() public {
        // epoch 2 at price p2
        _requestDeposit(alice, 1_000e6);
        _closeAndFulfill();
        uint256 s1 = _epoch(2).sharesMinted;

        // epoch 3 at a higher price: the auto-roll merges both entitlements
        vm.warp(block.timestamp + 2 hours);
        _requestDeposit(alice, 2_000e6);
        _closeAndFulfill();
        uint256 s2 = _epoch(3).sharesMinted;

        assertGt(s1 * 2, s2, "the two epochs settled at different prices");
        assertEq(vault.maxDeposit(alice), 3_000e6, "assets aggregate across epochs");
        assertEq(vault.maxMint(alice), s1 + s2, "shares aggregate across epochs");
        assertEq(vault.claimableDepositRequest(2, alice), 3_000e6, "fungible ledger ignores requestId");
        assertEq(vault.claimableDepositRequest(999, alice), 3_000e6);

        vm.prank(alice);
        uint256 consumed = vault.mint(s1 + s2, alice, alice);
        assertEq(consumed, 3_000e6, "full claim consumes the exact merged pair");
        assertEq(vault.balanceOf(alice), s1 + s2);
    }

    function test_multiEpochAggregation_redeemSide() public {
        (, uint256 owned) = _fulfilledDeposit(alice, 10_000e6);
        vm.prank(alice);
        vault.mint(owned, alice, alice);

        vm.prank(alice);
        vault.requestRedeem(2_000e6, alice, alice);
        _closeAndFulfill();
        uint256 a1 = _epoch(3).assetsSetAside;

        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vault.requestRedeem(1_000e6, alice, alice); // auto-rolls epoch 3 first
        _closeAndFulfill();
        uint256 a2 = _epoch(4).assetsSetAside;

        assertEq(vault.maxRedeem(alice), 3_000e6);
        assertEq(vault.maxWithdraw(alice), a1 + a2);
        assertEq(vault.claimableRedeemRequest(0, alice), 3_000e6, "fungible ledger ignores requestId");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(a1 + a2, alice, alice);
        assertEq(usdc.balanceOf(alice) - balBefore, a1 + a2);
    }

    function test_maxViews_reflectFulfilledSlotBeforeAnyTouchpoint() public {
        _requestDeposit(alice, 5_000e6);
        _close();
        assertEq(vault.maxDeposit(alice), 0, "nothing claimable while CLOSED");
        _fulfill();

        (uint256 storedA,) = vault.claimableDeposit(alice);
        assertEq(storedA, 0, "storage ledger not written yet (lazy roll)");
        assertEq(vault.maxDeposit(alice), 5_000e6, "the view simulates the roll");
        assertEq(vault.maxMint(alice), _epoch(2).sharesMinted);
    }

    function test_maxViews_zeroForStrangers() public view {
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        assertEq(vault.maxWithdraw(bob), 0);
        assertEq(vault.maxRedeem(bob), 0);
    }

    // ==================================================================
    // Fuzz — any partial-claim split recovers the exact entitlement
    // ==================================================================

    function testFuzz_deposit_partialClaimSplit_alwaysExact(uint256 cut) public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 10_000e6);
        cut = bound(cut, 1, a - 1);

        vm.startPrank(alice);
        uint256 out1 = vault.deposit(cut, alice, alice);
        uint256 out2 = vault.deposit(a - cut, alice, alice);
        vm.stopPrank();

        assertEq(out1, Math.mulDiv(cut, s, a), "partial payout floors");
        assertEq(out1 + out2, s, "any split recovers exactly the entitlement");
        assertEq(vault.maxMint(alice), 0);
    }

    function testFuzz_mint_partialClaimSplit_alwaysExact(uint256 cut) public {
        (uint256 a, uint256 s) = _fulfilledDeposit(alice, 10_000e6);
        cut = bound(cut, 1, s - 1);

        vm.startPrank(alice);
        uint256 in1 = vault.mint(cut, alice, alice);
        uint256 in2 = vault.mint(s - cut, alice, alice);
        vm.stopPrank();

        assertEq(in1 + in2, a, "assets consumed sum to the exact entitlement");
        assertEq(vault.balanceOf(alice), s);
        assertEq(vault.maxDeposit(alice), 0);
    }

    function testFuzz_withdraw_partialClaimSplit_alwaysExact(uint256 cut) public {
        (uint256 a, uint256 s) = _fulfilledRedeem(alice, 10_000e6, 5_000e6);
        cut = bound(cut, 1, a - 1);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 in1 = vault.withdraw(cut, alice, alice);
        uint256 in2 = vault.withdraw(a - cut, alice, alice);
        vm.stopPrank();

        assertEq(in1 + in2, s, "shares consumed sum to the exact entitlement");
        assertEq(usdc.balanceOf(alice) - balBefore, a);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function testFuzz_redeem_partialClaimSplit_alwaysExact(uint256 cut) public {
        (uint256 a, uint256 s) = _fulfilledRedeem(alice, 10_000e6, 5_000e6);
        cut = bound(cut, 1, s - 1);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 out1 = vault.redeem(cut, alice, alice);
        uint256 out2 = vault.redeem(s - cut, alice, alice);
        vm.stopPrank();

        assertEq(out1 + out2, a, "payouts sum to the exact entitlement");
        assertEq(usdc.balanceOf(alice) - balBefore, a);
        assertEq(vault.maxRedeem(alice), 0);
    }
}
