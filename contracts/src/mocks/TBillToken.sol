// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NAVOracle} from "../NAVOracle.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @title TBillToken — mock tokenized T-Bill with its own primary market
/// @notice The security the fund invests in (design decision D3). Anyone can
/// `subscribe` (buy at the oracle price) or `redeem` (sell back at the oracle
/// price); the fund manager is the intended main user, investing idle cash
/// after fulfillments and divesting to fund redemption payouts.
///
/// The "issuer" (the State/Treasury of the simulation) is ambient, not a
/// connected role: at redemption it pays principal + accrued interest, the
/// way a maturing T-Bill does — mock-implemented by minting the USDC
/// shortfall (the treasury collected only principal at subscription).
///
/// @dev 6 decimals, deliberately matching USDC: value conversions are then a
/// single 1e18-scaled multiplication by the oracle price, with no
/// decimals-bridging term to get wrong.
contract TBillToken is ERC20 {
    using SafeERC20 for IERC20;

    NAVOracle public immutable oracle;
    MockUSDC public immutable usdc;

    event Subscribed(address indexed buyer, uint256 usdcIn, uint256 tbillOut);
    event Redeemed(address indexed seller, uint256 tbillIn, uint256 usdcOut);

    error AmountRoundsToZero();

    constructor(NAVOracle oracle_, MockUSDC usdc_) ERC20("Mock 13-Week T-Bill", "TBILL") {
        oracle = oracle_;
        usdc = usdc_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Buy T-Bills at the current oracle price.
    /// @dev Floor division: the buyer bears the dust, the issuer never
    /// over-issues — same rounding policy as the vault (in favor of the
    /// system, docs/invariants-and-testing.md I2).
    function subscribe(uint256 usdcAmount) external returns (uint256 tbillAmount) {
        tbillAmount = (usdcAmount * oracle.PRICE_SCALE()) / oracle.price();
        if (tbillAmount == 0) revert AmountRoundsToZero();
        // The mock reverts on failure anyway, but checked transfers stay the
        // reflex everywhere tokens move — no exceptions for "known" tokens.
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
        _mint(msg.sender, tbillAmount);
        emit Subscribed(msg.sender, usdcAmount, tbillAmount);
    }

    /// @notice Sell T-Bills back at the current oracle price
    /// (principal + accrued interest).
    function redeem(uint256 tbillAmount) external returns (uint256 usdcAmount) {
        usdcAmount = (tbillAmount * oracle.price()) / oracle.PRICE_SCALE();
        if (usdcAmount == 0) revert AmountRoundsToZero();
        _burn(msg.sender, tbillAmount);
        // The treasury holds only subscribed principal; interest above it is
        // "printed" by the issuer — the simulation's yield source (D3).
        uint256 treasury = usdc.balanceOf(address(this));
        if (treasury < usdcAmount) {
            usdc.mint(address(this), usdcAmount - treasury);
        }
        IERC20(usdc).safeTransfer(msg.sender, usdcAmount);
        emit Redeemed(msg.sender, tbillAmount, usdcAmount);
    }
}
