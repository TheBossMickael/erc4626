// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {Escrow} from "../../src/Escrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC7540Operator} from "../../src/interfaces/IERC7540.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Exhaustive unauthorized-caller matrix (I8):
///  - MANAGER_ROLE surface (epoch machine + portfolio), incl. the nuance
///    that DEFAULT_ADMIN_ROLE does NOT imply MANAGER_ROLE;
///  - Escrow movements: vault only;
///  - Oracle admin surface: owner only;
///  - ERC-7540 caller rules: operator standing for requests/claims/cancels,
///    the ERC-20 allowance path of requestRedeem, and the spec rule that a
///    share allowance is NOT a claim authorization.
contract AccessControlMatrixTest is BaseTest {
    // ==================================================================
    // MANAGER_ROLE (D10)
    // ==================================================================

    function test_managerSurface_revertsForStrangerAndForAdmin() public {
        bytes32 managerRole = vault.MANAGER_ROLE();
        // the deployer (this contract) holds DEFAULT_ADMIN_ROLE but NOT
        // MANAGER_ROLE: role separation is real, not cosmetic
        address[2] memory intruders = [alice, address(this)];

        for (uint256 i; i < intruders.length; ++i) {
            address caller = intruders[i];
            bytes memory err = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, managerRole
            );

            vm.expectRevert(err);
            vm.prank(caller);
            vault.closeEpoch();

            vm.expectRevert(err);
            vm.prank(caller);
            vault.fulfillEpoch();

            vm.expectRevert(err);
            vm.prank(caller);
            vault.invest(1);

            vm.expectRevert(err);
            vm.prank(caller);
            vault.divest(1);
        }
    }

    function test_adminGrantsAndRevokesManager() public {
        bytes32 managerRole = vault.MANAGER_ROLE();

        vault.grantRole(managerRole, alice); // deployer == admin == this
        vm.prank(alice);
        vault.closeEpoch();
        assertEq(vault.currentEpochId(), 2, "granted manager can turn the cycle");

        vault.revokeRole(managerRole, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, managerRole)
        );
        vm.prank(alice);
        vault.fulfillEpoch();
    }

    function test_nonAdminCannotGrantRoles() public {
        bytes32 managerRole = vault.MANAGER_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vm.prank(alice);
        vault.grantRole(managerRole, alice);
    }

    // ==================================================================
    // Escrow: vault-only custody (T11)
    // ==================================================================

    function test_escrow_transferTo_onlyVault() public {
        usdc.mint(address(escrow), 1_000e6);

        address[3] memory intruders = [alice, manager, address(this)];
        for (uint256 i; i < intruders.length; ++i) {
            vm.expectRevert(Escrow.NotVault.selector);
            vm.prank(intruders[i]);
            escrow.transferTo(usdc, intruders[i], 1);
        }

        // only the vault can move escrowed funds
        vm.prank(address(vault));
        escrow.transferTo(usdc, bob, 1_000e6);
        assertEq(usdc.balanceOf(bob), 1_000e6);
    }

    // ==================================================================
    // Oracle admin surface (T10 trust assumption)
    // ==================================================================

    function test_oracle_adminSurface_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);

        vm.startPrank(alice);
        vm.expectRevert(err);
        oracle.setRateBps(100);
        vm.expectRevert(err);
        oracle.setTimeScale(1);
        vm.expectRevert(err);
        oracle.applyShock(100);
        vm.stopPrank();

        oracle.setRateBps(100); // the owner (deployer) can
        assertEq(oracle.rateBps(), 100);
    }

    // ==================================================================
    // ERC-7540 requests: owner rules
    // ==================================================================

    function test_requestDeposit_forThirdPartyOwner_requiresOperator() public {
        _mintAndApprove(alice, 1_000e6);

        // spec: owner MUST be msg.sender or have approved it as operator —
        // there is no ERC-20 allowance path on the deposit side
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(bob);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        vault.requestDeposit(1_000e6, alice, alice);
        assertEq(vault.pendingDepositRequest(1, alice), 1_000e6, "operator pulled the owner's approved assets");
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_requestRedeem_thirdParty_allowancePath() public {
        uint256 shares = _seedVault(alice, 1_000e6);

        // neither operator nor allowance: the ERC-20 path reverts
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);

        // a share allowance authorizes the request and is spent
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);
        assertEq(vault.allowance(alice, bob), 0, "allowance consumed");
        assertEq(vault.pendingRedeemRequest(2, alice), shares);
    }

    function test_requestRedeem_infiniteAllowanceNotConsumed() public {
        uint256 shares = _seedVault(alice, 1_000e6);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);
        assertEq(vault.allowance(alice, bob), type(uint256).max, "infinite allowance untouched (OZ semantics)");
    }

    function test_requestRedeem_operator_skipsAllowance() public {
        uint256 shares = _seedVault(alice, 1_000e6);
        vm.prank(alice);
        vault.setOperator(eve, true);

        vm.prank(eve); // zero ERC-20 allowance: operator standing suffices
        vault.requestRedeem(shares, alice, alice);
        assertEq(vault.pendingRedeemRequest(2, alice), shares);
    }

    // ==================================================================
    // Claims: controller-or-operator only
    // ==================================================================

    function test_claims_requireControllerOrOperator() public {
        // both-side claimables for alice
        _seedVault(alice, 2_000e6);
        _requestDeposit(alice, 1_000e6);
        _requestRedeem(alice, 500e6);
        _closeAndFulfill();

        vm.startPrank(bob); // neither controller nor operator
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vault.deposit(1, bob, alice);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vault.mint(1, bob, alice);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vault.withdraw(1, bob, alice);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vault.redeem(1, bob, alice);
        vm.stopPrank();

        // spec: the ERC-20 share-allowance path of plain 4626 does NOT apply
        // to claims — shares were escrowed at request time
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(bob);
        vault.redeem(1, bob, alice);
    }

    function test_operatorClaims_forController_eventKeyedOnController() public {
        _requestDeposit(alice, 1_000e6);
        _closeAndFulfill(); // par: 1_000e6 shares
        vm.prank(alice);
        vault.setOperator(eve, true);

        // spec: the first Deposit-event param is the CONTROLLER, even when
        // an operator is msg.sender
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(alice, bob, 1_000e6, 1_000e6);
        vm.prank(eve);
        uint256 sharesOut = vault.deposit(1_000e6, bob, alice);

        assertEq(sharesOut, 1_000e6);
        assertEq(vault.balanceOf(bob), 1_000e6, "receiver chosen by the operator");
        assertEq(vault.maxDeposit(alice), 0, "controller's ledger debited");
    }

    // ==================================================================
    // Cancels: controller-or-operator only, refund to the controller
    // ==================================================================

    function test_cancelDeposit_requiresControllerOrOperator_refundToController() public {
        _requestDeposit(alice, 1_000e6);

        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(bob);
        vault.cancelDepositRequest(alice);

        vm.prank(alice);
        vault.setOperator(eve, true);
        vm.prank(eve);
        vault.cancelDepositRequest(alice);
        assertEq(usdc.balanceOf(alice), 1_000e6, "refund reaches the controller, never the operator");
        assertEq(usdc.balanceOf(eve), 0);
    }

    function test_cancelRedeem_requiresControllerOrOperator() public {
        uint256 shares = _seedVault(alice, 1_000e6);
        _requestRedeem(alice, shares);

        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(bob);
        vault.cancelRedeemRequest(alice);

        vm.prank(alice);
        vault.setOperator(eve, true);
        vm.prank(eve);
        vault.cancelRedeemRequest(alice);
        assertEq(vault.balanceOf(alice), shares, "shares returned to the controller");
    }

    // ==================================================================
    // setOperator: toggle, scope, event
    // ==================================================================

    function test_setOperator_toggleAndScope() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540Operator.OperatorSet(alice, eve, true);
        vm.prank(alice);
        bool ok = vault.setOperator(eve, true);
        assertTrue(ok);
        assertTrue(vault.isOperator(alice, eve));

        // operator standing is scoped per controller: eve may not act for bob
        _mintAndApprove(bob, 100e6);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(eve);
        vault.requestDeposit(100e6, bob, bob);

        // revocation cuts access immediately
        vm.prank(alice);
        vault.setOperator(eve, false);
        assertFalse(vault.isOperator(alice, eve));
        _mintAndApprove(alice, 100e6);
        vm.expectRevert(RWAVault.NotAuthorized.selector);
        vm.prank(eve);
        vault.requestDeposit(100e6, alice, alice);
    }
}
