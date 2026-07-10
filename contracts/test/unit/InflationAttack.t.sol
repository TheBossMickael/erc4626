// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice T6 (first-depositor / inflation attack) and T7 (direct donations):
/// OZ's virtual-share offset plus batch pricing make the donation grief
/// strictly unprofitable, and no donation can discriminate inside an epoch —
/// the whole batch shares one rate by construction (I1).
contract InflationAttackTest is BaseTest {
    address internal mallory;

    function setUp() public override {
        super.setUp();
        mallory = makeAddr("mallory");
    }

    function test_firstDepositor_parRoundTrip() public {
        // no accrual is possible (the vault holds no T-Bill): strict par
        _requestDeposit(alice, 1_000e6);
        _closeAndFulfill();
        assertEq(_epoch(1).sharesMinted, 1_000e6, "first epoch mints 1:1");

        vm.prank(alice);
        vault.mint(1_000e6, alice, alice);
        _requestRedeem(alice, 1_000e6);
        _closeAndFulfill();

        vm.prank(alice);
        uint256 out = vault.redeem(1_000e6, alice, alice);
        assertEq(out, 1_000e6, "full round trip returns the exact principal");
    }

    /// @dev The classic grief: donate straight to the vault before the first
    /// epoch settles, skewing the strike price. Batch pricing means the
    /// attacker cannot target a victim (one rate for everyone, I1), and the
    /// donation lands in the pot the WHOLE batch buys: the attacker recovers
    /// at most their pro-rata fraction of it — a strict loss whenever any
    /// other depositor exists.
    function testFuzz_firstEpochDonation_attackerNeverProfits(uint256 donation) public {
        donation = bound(donation, 1, 1_000_000e6);

        _requestDeposit(alice, 1_000e6); // the victim
        _requestDeposit(mallory, 100e6); // the attacker's own request
        usdc.mint(mallory, donation);
        vm.prank(mallory);
        // MockUSDC is OZ ERC20: reverts on failure, return value always true
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(vault), donation); // the grief

        _closeAndFulfill();

        // I1: one price for the whole batch, donation or not.
        // Cross-product bound: |eA*pM - eM*pA| < max(pA, pM) <=> equal rates
        // up to the 1-wei pro-rata floor.
        uint256 eAlice = vault.maxMint(alice);
        uint256 eMallory = vault.maxMint(mallory);
        uint256 lhs = eAlice * 100e6;
        uint256 rhs = eMallory * 1_000e6;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLt(diff, 1_000e6, "I1: attacker and victim settle at the same rate");

        // No profit: the attacker's claimable value is capped by their
        // pro-rata slice of (batch + donation) — they recover at most
        // ~1/11th of what they donated (their share of the batch), the rest
        // is a gift to the other depositors and to the virtual share.
        uint256 valueOut = vault.convertToAssets(eMallory);
        uint256 maxRecovery = 100e6 + Math.mulDiv(100e6, donation + 1, 1_100e6) + 1;
        assertLe(valueOut, maxRecovery, "T6: donation grief must never profit");
    }

    /// @dev T7 on a seeded vault: a donation moves the NAV up for everyone
    /// between epochs — a gift to current holders — and the next batch still
    /// settles at one uniform (higher) price.
    function test_donationOnSeededVault_benefitsHoldersUniformly() public {
        _seedVault(alice, 10_000e6);
        uint256 ppsBefore = _pps();

        usdc.mint(mallory, 1_000e6);
        vm.prank(mallory);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(vault), 1_000e6);

        assertGt(_pps(), ppsBefore, "donation raises the NAV for existing holders");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow unaffected by donations (D9)");

        // a batch settling after the donation shares one price (I1)
        _requestDeposit(bob, 1_000e6);
        _requestDeposit(carol, 3_000e6);
        _closeAndFulfill();

        uint256 eBob = vault.maxMint(bob);
        uint256 eCarol = vault.maxMint(carol);
        uint256 lhs = eBob * 3_000e6;
        uint256 rhs = eCarol * 1_000e6;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLt(diff, 3_000e6, "I1 holds through donations");
    }
}
