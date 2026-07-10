// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice ERC-165 surface: the EIP-mandated interface ids (hardcoded in the
/// vault on purpose — the local interfaces are partial), the inherited
/// AccessControl/ERC-165 ids, and the 7575 `share()` identity.
contract ERC165Test is BaseTest {
    function test_supportsInterface_erc7540Surface() public view {
        assertTrue(vault.supportsInterface(0xe3bc4e65), "ERC-7540 operator methods");
        assertTrue(vault.supportsInterface(0x2f0a18c5), "ERC-7575 vault");
        assertTrue(vault.supportsInterface(0xce3bbe50), "ERC-7540 asynchronous deposit");
        assertTrue(vault.supportsInterface(0x620ee8e4), "ERC-7540 asynchronous redemption");
    }

    function test_supportsInterface_inheritedSurface() public view {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId), "ERC-165 itself");
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId), "AccessControl");
    }

    function test_supportsInterface_negatives() public view {
        assertFalse(vault.supportsInterface(0xffffffff), "ERC-165 mandates false for 0xffffffff");
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function test_erc7575_shareIsTheVault() public view {
        assertEq(vault.share(), address(vault), "single-token 7575 vault: the share IS the vault");
        assertEq(vault.asset(), address(usdc));
    }
}
