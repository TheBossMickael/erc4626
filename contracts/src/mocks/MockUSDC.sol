// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC — demo stand-in for the fund's settlement asset
/// @notice 6 decimals like the real USDC, so all amounts read realistically
/// in the frontend and decimal-handling bugs can't hide behind 18-decimals
/// convenience.
/// @dev The open `mint` is a demo faucet AND the mechanism by which the mock
/// T-Bill issuer pays accrued interest at redemption (see TBillToken).
/// Obviously never deployable as-is outside a simulation.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet — anyone can mint (demo only).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
