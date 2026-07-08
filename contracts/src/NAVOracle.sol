// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NAVOracle — simulated T-Bill price feed
/// @notice Prices the mock T-Bill in asset (USDC) terms, 1e18 fixed-point,
/// starting at 1.0. The price accrues a configurable annualized rate over a
/// configurable *time scale* (e.g. 1 real minute = 1 simulated day) so that
/// T-Bill-grade yield is actually visible during a live demo — 4.5% APR over
/// 5 real minutes is otherwise a flat line. The admin can also inject one-off
/// mark-to-market shocks (design decision D8).
///
/// @dev Accrual is piecewise-linear simple interest between checkpoints;
/// compounding happens only when a checkpoint occurs (any admin change).
/// Why: the trajectory stays deterministic and trivially auditable, and at
/// demo horizons the difference vs continuous compounding is negligible.
/// Every admin action checkpoints *first*, so parameter changes never apply
/// retroactively to already-elapsed time.
///
/// Trust model (see docs/threat-model.md, T10): the oracle admin is trusted —
/// it stands in for the fund accountant / custodian NAV feed of a real fund.
contract NAVOracle is Ownable {
    uint256 public constant PRICE_SCALE = 1e18;

    /// @dev Caps are demo-safety rails: they bound fat-finger damage, they
    /// are not economic parameters.
    uint256 public constant MAX_RATE_BPS = 2_000; // 20% APR
    uint256 public constant MAX_TIME_SCALE = 1_000_000; // 1 real sec <= ~11.6 simulated days
    int256 public constant MAX_SHOCK_BPS = 5_000; // +/-50% per shock

    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;

    /// @notice Annualized simple rate, in basis points (450 = 4.5%).
    uint256 public rateBps;
    /// @notice Simulated seconds elapsing per real second (1 = real time).
    uint256 public timeScale;

    uint256 private _checkpointPrice;
    uint64 private _checkpointAt;

    event RateSet(uint256 rateBps, uint256 priceAtCheckpoint);
    event TimeScaleSet(uint256 timeScale, uint256 priceAtCheckpoint);
    event ShockApplied(int256 shockBps, uint256 newPrice);

    error InvalidRate();
    error InvalidTimeScale();
    error InvalidShock();

    constructor(uint256 initialRateBps, uint256 initialTimeScale) Ownable(msg.sender) {
        if (initialRateBps > MAX_RATE_BPS) revert InvalidRate();
        if (initialTimeScale == 0 || initialTimeScale > MAX_TIME_SCALE) revert InvalidTimeScale();
        rateBps = initialRateBps;
        timeScale = initialTimeScale;
        _checkpointPrice = PRICE_SCALE; // par: 1 TBILL = 1 USDC at t0
        _checkpointAt = uint64(block.timestamp);
    }

    /// @notice Current price of 1 TBILL in USDC terms, 1e18 fixed-point.
    /// @dev Lazily computed — no storage write is ever needed to read a
    /// fresh price, so the vault's NAV is always current.
    function price() public view returns (uint256) {
        uint256 simulatedElapsed = (block.timestamp - _checkpointAt) * timeScale;
        return _checkpointPrice + (_checkpointPrice * rateBps * simulatedElapsed) / (BPS * YEAR);
    }

    /// @notice Update the annualized rate (checkpoints accrual first).
    function setRateBps(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert InvalidRate();
        _checkpoint();
        rateBps = newRateBps;
        emit RateSet(newRateBps, _checkpointPrice);
    }

    /// @notice Update the demo time scale (checkpoints accrual first).
    function setTimeScale(uint256 newTimeScale) external onlyOwner {
        if (newTimeScale == 0 || newTimeScale > MAX_TIME_SCALE) revert InvalidTimeScale();
        _checkpoint();
        timeScale = newTimeScale;
        emit TimeScaleSet(newTimeScale, _checkpointPrice);
    }

    /// @notice One-off multiplicative mark-to-market move, in basis points
    /// (e.g. -30 = -0.30%). Models rate moves / credit events for the demo.
    /// @dev Shocks landing between an epoch's cut-off and its fulfillment
    /// hit already-binding orders — deliberate, that is how real funds work
    /// (design decisions D5/D7/D8).
    function applyShock(int256 shockBps) external onlyOwner {
        if (shockBps <= -MAX_SHOCK_BPS || shockBps > MAX_SHOCK_BPS) revert InvalidShock();
        _checkpoint();
        // Sign-split instead of signed math on the price itself: the only
        // casts left are on `shockBps`, provably in range after the bounds
        // check above.
        uint256 factorBps;
        if (shockBps >= 0) {
            // safe: shockBps is in [0, MAX_SHOCK_BPS], fits any uint
            // forge-lint: disable-next-line(unsafe-typecast)
            factorBps = BPS + uint256(shockBps);
        } else {
            // safe: -shockBps is in (0, MAX_SHOCK_BPS) and MAX_SHOCK_BPS < BPS,
            // so the subtraction cannot underflow (price never zeroes out)
            // forge-lint: disable-next-line(unsafe-typecast)
            factorBps = BPS - uint256(-shockBps);
        }
        _checkpointPrice = (_checkpointPrice * factorBps) / BPS;
        emit ShockApplied(shockBps, _checkpointPrice);
    }

    function _checkpoint() private {
        _checkpointPrice = price();
        _checkpointAt = uint64(block.timestamp);
    }
}
