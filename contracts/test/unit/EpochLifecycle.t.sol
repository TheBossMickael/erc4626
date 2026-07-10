// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice The epoch state machine (I9 unit side) and `fulfillEpoch()`:
/// empty epochs, one-sided epochs, netting, the short-of-cash revert before
/// `divest`, portfolio management, and the I3 price-continuity unit fuzz
/// over random epoch compositions (docs/invariants.md).
contract EpochLifecycleTest is BaseTest {
    // ==================================================================
    // State machine (I9)
    // ==================================================================

    function test_initialState() public view {
        assertEq(vault.currentEpochId(), 1, "ids start at 1 (0 is the empty-slot sentinel)");
        RWAVault.Epoch memory e = _epoch(1);
        assertEq(e.cutoffAt, 0);
        assertEq(e.fulfilledAt, 0);
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.decimals(), 6, "share decimals track the 6-decimals asset (offset 0)");
        assertEq(vault.totalAssets(), 0);
        assertEq(escrow.vault(), address(vault), "escrow bound to its deployer, no setter");
    }

    function test_closeEpoch_snapshotsTotalsAndOpensNext() public {
        _requestDeposit(alice, 1_000e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit RWAVault.EpochClosed(1, 1_000e6, 0);
        uint256 closedId = _close();

        assertEq(closedId, 1);
        assertEq(vault.currentEpochId(), 2, "the next epoch opens at cut-off");
        RWAVault.Epoch memory e = _epoch(1);
        assertEq(e.cutoffAt, block.timestamp);
        assertEq(e.fulfilledAt, 0, "CLOSED, not yet FULFILLED");
    }

    function test_closeEpoch_twiceWithoutFulfill_reverts() public {
        _close();
        vm.expectRevert(RWAVault.PreviousEpochNotFulfilled.selector);
        vm.prank(manager);
        vault.closeEpoch(); // at most one epoch awaits settlement (I9/D5)
    }

    function test_closeEpoch_afterFulfill_succeeds() public {
        _closeAndFulfill(); // epoch 1 settles (empty)
        uint256 closedId = _close(); // epoch 2 may now close
        assertEq(closedId, 2);
        assertEq(vault.currentEpochId(), 3);
    }

    function test_fulfillEpoch_withoutClosedEpoch_reverts() public {
        vm.expectRevert(RWAVault.NoEpochToFulfill.selector);
        vm.prank(manager);
        vault.fulfillEpoch();
    }

    function test_fulfillEpoch_twice_reverts() public {
        _closeAndFulfill();
        vm.expectRevert(RWAVault.NoEpochToFulfill.selector);
        vm.prank(manager);
        vault.fulfillEpoch(); // a FULFILLED epoch is immutable (I9)
    }

    // ==================================================================
    // fulfillEpoch — compositions
    // ==================================================================

    function test_fulfillEpoch_emptyEpoch() public {
        _close(); // the manager may turn the cycle on a quiet day

        vm.expectEmit(true, false, false, true, address(vault));
        emit RWAVault.EpochFulfilled(1, 0, 0, 0, 0, ONE_SHARE); // par NAV on an empty vault
        uint256 id = _fulfill();

        assertEq(id, 1);
        RWAVault.Epoch memory e = _epoch(1);
        assertEq(e.fulfilledAt, block.timestamp);
        assertEq(e.sharesMinted, 0);
        assertEq(e.assetsSetAside, 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_fulfillEpoch_firstEpoch_depositOnly_atPar() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 500e6);
        _close();

        vm.expectEmit(true, false, false, true, address(vault));
        emit RWAVault.EpochFulfilled(1, 1_500e6, 0, 1_500e6, 0, ONE_SHARE);
        _fulfill();

        assertEq(_epoch(1).sharesMinted, 1_500e6, "empty vault: strict 1:1 (virtual-share offset)");
        assertEq(vault.balanceOf(address(escrow)), 1_500e6, "batch shares minted to escrow, claimable");
        assertEq(usdc.balanceOf(address(vault)), 1_500e6, "subscription cash joined the fund");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(vault.totalAssets(), 1_500e6);
    }

    function test_fulfillEpoch_redeemOnly_withSufficientCash() public {
        _seedVault(alice, 2_000e6);
        _requestRedeem(alice, 800e6);
        _close();

        uint256 supplyBefore = vault.totalSupply();
        _fulfill();

        RWAVault.Epoch memory e = _epoch(2);
        assertEq(e.sharesMinted, 0);
        assertEq(e.assetsSetAside, 800e6, "par NAV: 1 share pays 1 asset");
        assertEq(vault.totalSupply(), supplyBefore - 800e6, "redeem shares burned at settlement (I5)");
        assertEq(usdc.balanceOf(address(vault)), 1_200e6);
        assertEq(usdc.balanceOf(address(escrow)), 800e6, "payout reserved in escrow, out of totalAssets");
    }

    function test_fulfillEpoch_netting_subscriptionsFundRedemptions() public {
        _seedVault(alice, 10_000e6);
        _invest(6_000e6); // 4_000e6 idle cash remains

        _requestDeposit(bob, 1_000e6);
        _requestRedeem(alice, 400e6);
        _close();

        uint256 setAsidePreview = vault.convertToAssets(400e6);
        uint256 vaultCashBefore = usdc.balanceOf(address(vault));
        uint256 tbillBefore = tbill.balanceOf(address(vault));
        uint256 supplyBefore = vault.totalSupply();

        _fulfill();

        RWAVault.Epoch memory e = _epoch(2);
        assertEq(e.assetsSetAside, setAsidePreview, "strike equals the pre-settlement conversion");
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultCashBefore + 1_000e6 - e.assetsSetAside,
            "net cash impact = subscriptions - payouts (D6)"
        );
        assertEq(usdc.balanceOf(address(escrow)), e.assetsSetAside, "payout reserved in escrow");
        assertEq(tbill.balanceOf(address(vault)), tbillBefore, "netting: the portfolio is untouched");
        assertEq(vault.totalSupply(), supplyBefore + e.sharesMinted - 400e6, "mint and burn settle atomically");
    }

    function test_fulfillEpoch_insufficientCash_revertsUntilDivest() public {
        _seedVault(alice, 10_000e6);
        _invest(9_500e6); // only 500e6 cash left

        _requestRedeem(alice, 5_000e6); // payout worth 5_000e6, far above cash
        _close();

        // step 3's final push reverts by design: the manager must divest
        // first, like a real fund selling T-Bills to fund redemptions.
        // Exact expectation: 500e6 cash (after the 9_500e6 investment)
        // cannot cover the 5_000e6 payout struck at par.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 500e6, 5_000e6)
        );
        vm.prank(manager);
        vault.fulfillEpoch();

        _divest(tbill.balanceOf(address(vault)));
        uint256 id = _fulfill();

        RWAVault.Epoch memory e = _epoch(id);
        assertEq(usdc.balanceOf(address(escrow)), e.assetsSetAside, "payout funded after divestment");
        assertEq(vault.pendingRedeemRequest(2, alice), 0);
        assertEq(vault.maxWithdraw(alice), e.assetsSetAside, "single redeemer earns the whole batch");
    }

    // ==================================================================
    // Portfolio management (D3)
    // ==================================================================

    function test_invest_navNeutralUpToDust() public {
        _seedVault(alice, 10_000e6);
        vm.warp(block.timestamp + 1 hours); // price > 1.0: rounding becomes real

        uint256 taBefore = vault.totalAssets();
        vm.expectEmit(false, false, false, false, address(vault));
        emit RWAVault.Invested(0, 0); // signature + emitter only
        _invest(7_000e6);
        uint256 taAfter = vault.totalAssets();

        assertLe(taAfter, taBefore + 1, "invest cannot create value");
        if (taBefore > taAfter) {
            assertLe(
                taBefore - taAfter,
                oracle.price() / oracle.PRICE_SCALE() + 2,
                "invest lost more than the primary market's floor dust"
            );
        }
    }

    function test_divest_realizesAccruedInterest() public {
        _seedVault(alice, 10_000e6);
        _invest(8_000e6); // price is exactly 1.0 at t0: 8_000e6 TBILL
        uint256 tbillBal = tbill.balanceOf(address(vault));

        vm.warp(block.timestamp + 1 hours); // ~60 simulated days of accrual

        uint256 expected = (tbillBal * oracle.price()) / oracle.PRICE_SCALE();
        uint256 cashBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(false, false, false, true, address(vault));
        emit RWAVault.Divested(tbillBal, expected);
        _divest(tbillBal);

        assertEq(usdc.balanceOf(address(vault)), cashBefore + expected, "principal + accrued interest");
        assertGt(expected, 8_000e6, "interest actually accrued");
        assertEq(tbill.balanceOf(address(vault)), 0);
    }

    // ==================================================================
    // I3 — NAV-per-share continuity across fulfillment (unit fuzz)
    // ==================================================================

    /// @dev Random epoch composition (deposit-heavy, redeem-heavy, netted,
    /// one-sided, empty), random accrual and mark-to-market shock landing
    /// between cut-off and settlement (binding orders, D5/D8): fulfilling
    /// must never drop the price, and any rise stays within rounding dust.
    ///
    /// Drift bound derivation: with virtual amounts a=A+1, s=S+1 and exact
    /// (real-number) settlement the price is unchanged: a'/s' == a/s. Each of
    /// the two batch floors loses < 1 unit, worth at most
    /// (a/s + 1)/s' in price terms, i.e. <= (p0 + ONE_SHARE + 1)/(S'+1) in the
    /// 1e6-scaled view, plus 1 wei of view flooring (margin +2 below).
    function testFuzz_fulfillEpoch_priceContinuity(
        uint256 depositAmount,
        uint256 redeemShares,
        uint256 warpSecs,
        int256 shockBps
    ) public {
        depositAmount = bound(depositAmount, 0, 5_000_000e6);
        warpSecs = bound(warpSecs, 0, 12 hours);
        shockBps = bound(shockBps, -2_000, 2_000);

        uint256 aliceShares = _seedVault(alice, 1_000_000e6);
        _invest(600_000e6);
        redeemShares = bound(redeemShares, 0, aliceShares / 2);

        if (depositAmount > 0) _requestDeposit(bob, depositAmount);
        if (redeemShares > 0) _requestRedeem(alice, redeemShares);
        _close();

        // accrual + shock while the orders are binding — exactly the T4
        // scenario the cut-off exists for
        vm.warp(block.timestamp + warpSecs);
        if (shockBps != 0) oracle.applyShock(shockBps);

        // the manager always divests everything before settling: full
        // divestment always covers assetsSetAside (<= totalAssets) and only
        // moves totalAssets by primary-market floor dust
        uint256 tb = tbill.balanceOf(address(vault));
        if (tb > 0 && (tb * oracle.price()) / oracle.PRICE_SCALE() > 0) _divest(tb);

        uint256 p0 = _pps();
        _fulfill();
        uint256 p1 = _pps();

        assertGe(p1, p0, "I3: fulfillment diluted remaining holders");
        uint256 maxDrift = (p0 + ONE_SHARE + 1) / (vault.totalSupply() + 1) + 2;
        assertLe(p1 - p0, maxDrift, "I3: price drift beyond rounding dust");
    }
}
