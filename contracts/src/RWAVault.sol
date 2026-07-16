// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC7540Operator, IERC7540Deposit, IERC7540Redeem} from "./interfaces/IERC7540.sol";
import {IERC7575} from "./interfaces/IERC7575.sol";
import {Escrow} from "./Escrow.sol";
import {NAVOracle} from "./NAVOracle.sol";
import {TBillToken} from "./mocks/TBillToken.sol";

/// @title RWAVault — tokenized T-Bill fund: ERC-4626 core, ERC-7540 surface
/// @notice One vault (design decision D1) that models an institutional fund
/// where settlement is not instantaneous. Share/asset accounting is OZ
/// `ERC4626`, untouched; both entry and exit are asynchronous (D2):
///
///   requestDeposit/requestRedeem  →  join the OPEN epoch (funds escrowed)
///   closeEpoch()   [manager]      →  cut-off: the epoch's orders are binding
///   fulfillEpoch() [manager]      →  the whole batch settles at ONE price,
///                                    struck at that moment (forward pricing)
///   deposit/mint/withdraw/redeem  →  claim what fulfillment produced
///
/// Core invariant (I1): every request of an epoch converts at exactly the
/// same rate — per-user entitlements are pro-rata shares of the recorded
/// batch result, so intra-epoch timing buys nothing, by construction.
///
/// The portfolio (D3) is cash (USDC) + a mock T-Bill priced by `NAVOracle`;
/// `totalAssets() = cash + tbillBalance × price`. Pending and claimable funds
/// live in a separate `Escrow` (D9), so `totalAssets()` is physically unable
/// to count money that does not belong to the fund yet (threat T2).
///
/// Roles (D10): `MANAGER_ROLE` turns the cycle and manages the portfolio but
/// cannot choose prices (NAV = oracle + accounting). ERC-7540 "operators" are
/// user-level delegates, unrelated to the manager.
/// @dev Spec references: https://eips.ethereum.org/EIPS/eip-7540 and
/// docs/contracts-tour.md (the guided tour of this contract's mechanics).
contract RWAVault is
    ERC4626,
    AccessControl,
    ReentrancyGuard,
    IERC7540Operator,
    IERC7540Deposit,
    IERC7540Redeem,
    IERC7575
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Roles & linked contracts
    // ---------------------------------------------------------------------

    /// @notice Fund manager / transfer agent: epoch cycle + portfolio.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Vault-only custody of pending and claimable funds (D9).
    /// @dev Deployed by this constructor, so `escrow.vault == address(this)`
    /// is bound once, with no setter and no owner.
    Escrow public immutable escrow;

    /// @notice The mock security the fund invests in (D3).
    TBillToken public immutable tbill;

    /// @notice Prices the T-Bill in asset terms, 1e18 fixed-point.
    NAVOracle public immutable oracle;

    /// @dev `oracle.PRICE_SCALE()`, captured once at deployment: totalAssets()
    /// is the hot path of every conversion — no external call to read a
    /// constant that cannot change.
    uint256 private immutable _priceScale;

    // ---------------------------------------------------------------------
    // Epoch machine storage (docs/contracts-tour.md, "The epoch machine")
    // ---------------------------------------------------------------------

    struct Epoch {
        uint256 totalDepositAssets; // aggregated requestDeposit amounts
        uint256 totalRedeemShares; // aggregated requestRedeem amounts
        uint256 sharesMinted; // set at fulfillment (deposit-side result)
        uint256 assetsSetAside; // set at fulfillment (redeem-side result)
        uint64 cutoffAt; // closeEpoch timestamp (0 = still open)
        uint64 fulfilledAt; // fulfillEpoch timestamp (0 = not fulfilled)
    }

    /// @dev One pending slot per controller per direction (D4). Bounded
    /// storage, no epoch enumeration: a fulfilled slot is rolled into the
    /// claimable ledger at the controller's next touchpoint.
    struct UserSlot {
        uint128 pendingAmount; // assets (deposit side) or shares (redeem side)
        uint64 epochId; // epoch the pending amount belongs to
    }

    /// @dev Post-roll claimable ledger, aggregated across epochs. Both
    /// denominations are tracked because the spec mandates claims in either
    /// unit (deposit(assets) AND mint(shares); withdraw(assets) AND
    /// redeem(shares)) with partial claims: once entitlements from epochs at
    /// different rates aggregate, converting one unit into the other is only
    /// possible pro-rata against this pair.
    /// Deposit side: `assets` = fulfilled deposit assets still unclaimed,
    /// `shares` = shares those assets earned. Redeem side: `shares` =
    /// fulfilled redeem shares still unclaimed, `assets` = payout they earned.
    struct ClaimBalance {
        uint256 assets;
        uint256 shares;
    }

    /// @notice Epoch data; `epochs(id)` is the frontend's state source.
    /// @dev State is derived, not stored: OPEN ⇔ id == currentEpochId;
    /// CLOSED ⇔ cutoffAt != 0 && fulfilledAt == 0; FULFILLED ⇔ fulfilledAt != 0.
    mapping(uint256 epochId => Epoch) public epochs;

    /// @notice The currently OPEN epoch (ids start at 1; 0 is a sentinel).
    uint256 public currentEpochId;

    /// @notice Pending deposit slot per controller.
    mapping(address controller => UserSlot) public depositSlot;

    /// @notice Pending redeem slot per controller.
    mapping(address controller => UserSlot) public redeemSlot;

    /// @notice Claimable ledger, deposit side (see ClaimBalance).
    mapping(address controller => ClaimBalance) public claimableDeposit;

    /// @notice Claimable ledger, redeem side (see ClaimBalance).
    mapping(address controller => ClaimBalance) public claimableRedeem;

    /// @inheritdoc IERC7540Operator
    mapping(address controller => mapping(address operator => bool)) public override isOperator;

    // ---------------------------------------------------------------------
    // Events (7540 request events come from the interfaces)
    // ---------------------------------------------------------------------

    /// @notice Cut-off: epoch `epochId`'s orders became binding; the next
    /// epoch is open for requests.
    event EpochClosed(uint256 indexed epochId, uint256 totalDepositAssets, uint256 totalRedeemShares);

    /// @notice Epoch `epochId` settled. `navPerShare` is the price struck in
    /// step 1 (assets per one whole share), recorded so the frontend's NAV
    /// timeline can place fulfillment markers without archive-node queries.
    event EpochFulfilled(
        uint256 indexed epochId,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares,
        uint256 sharesMinted,
        uint256 assetsSetAside,
        uint256 navPerShare
    );

    /// @notice Pre-cut-off cancellation (D7): full pending refund.
    event DepositRequestCanceled(address indexed controller, uint256 indexed epochId, uint256 assets);
    event RedeemRequestCanceled(address indexed controller, uint256 indexed epochId, uint256 shares);

    /// @notice A fulfilled pending was rolled into the claimable ledger
    /// (lazy settlement — fires at the controller's next touchpoint, not at
    /// fulfillment).
    event DepositClaimable(address indexed controller, uint256 indexed epochId, uint256 assets, uint256 shares);
    event RedeemClaimable(address indexed controller, uint256 indexed epochId, uint256 shares, uint256 assets);

    /// @notice Manager moved fund cash into / out of the T-Bill portfolio.
    event Invested(uint256 assetsIn, uint256 tbillOut);
    event Divested(uint256 tbillIn, uint256 assetsOut);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAmount();
    error NotAuthorized();
    error AssetMismatch();
    /// @dev The controller's slot sits in a CLOSED, not-yet-fulfilled epoch:
    /// the order is binding and the slot is busy (D4 narrow window).
    error PendingRequestUnfulfilled();
    error NoPendingRequest();
    /// @dev Cancellation after cut-off: the order is binding (D7).
    error RequestNotCancelable();
    /// @dev At most one epoch awaits settlement (D5).
    error PreviousEpochNotFulfilled();
    error NoEpochToFulfill();
    error ExceedsClaimable(uint256 requested, uint256 claimable);
    /// @dev Spec-mandated: the price is unknowable at request time.
    error PreviewNotSupported();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param asset_ the settlement asset (MockUSDC in the demo, 6 decimals)
    /// @param tbill_ the mock security; must settle in the same `asset_`
    /// @param oracle_ the NAV oracle pricing `tbill_`
    /// @param manager granted MANAGER_ROLE; msg.sender gets DEFAULT_ADMIN_ROLE
    constructor(IERC20 asset_, TBillToken tbill_, NAVOracle oracle_, address manager)
        ERC20("Tokenized T-Bill Fund Share", "fTBILL")
        ERC4626(asset_)
    {
        // Wiring sanity: if the T-Bill's settlement token differed from the
        // vault's asset, invest/divest would corrupt totalAssets silently.
        if (address(tbill_.usdc()) != address(asset_)) revert AssetMismatch();
        tbill = tbill_;
        oracle = oracle_;
        _priceScale = oracle_.PRICE_SCALE();
        escrow = new Escrow();
        currentEpochId = 1; // id 0 stays a sentinel (empty slots point at it)
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, manager);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 core override — the portfolio NAV (D3)
    // ---------------------------------------------------------------------

    /// @notice Fund NAV: idle cash + T-Bill position at the oracle price.
    /// @dev Pending/claimable funds are in the escrow, a different address —
    /// they cannot appear here no matter what this function forgets (D9/T2).
    function totalAssets() public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 tbillValue = (tbill.balanceOf(address(this)) * oracle.price()) / _priceScale;
        return cash + tbillValue;
    }

    // ---------------------------------------------------------------------
    // ERC-7540 requests
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    /// @dev Assets go straight to escrow. A previous fulfilled pending is
    /// rolled first, so the slot aggregates only within the OPEN epoch;
    /// reverts while the previous pending awaits settlement (D4).
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (assets == 0) revert ZeroAmount();
        // Spec: "owner MUST equal msg.sender unless the owner has approved
        // the msg.sender as an operator." (No ERC-20 allowance path here —
        // the vault has no allowance mechanism over the asset.)
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotAuthorized();

        _rollDeposit(controller);
        requestId = _joinOpenEpoch(depositSlot[controller], assets);
        epochs[requestId].totalDepositAssets += assets;

        IERC20(asset()).safeTransferFrom(owner, address(escrow), assets);
        emit DepositRequest(controller, owner, requestId, msg.sender, assets);
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev Shares go to escrow un-burned: they stay in totalSupply() until
    /// fulfillment, so the strike price still counts them as outstanding —
    /// exactly the economics of a not-yet-settled redemption order.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        // Spec: approval "may come either from ERC-20 approval over the
        // shares of owner or if the owner has approved the msg.sender as an
        // operator". Operators skip the allowance; third parties spend it.
        if (owner != msg.sender && !isOperator[owner][msg.sender]) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _rollRedeem(controller);
        requestId = _joinOpenEpoch(redeemSlot[controller], shares);
        epochs[requestId].totalRedeemShares += shares;

        _transfer(owner, address(escrow), shares);
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    /// @dev Shared slot mechanics of both request directions. Callers roll
    /// the slot first, so a non-empty slot here can only be in the OPEN
    /// epoch (aggregate into it) or in the single CLOSED-unfulfilled epoch
    /// (binding order, slot busy — revert; narrow window, D4).
    function _joinOpenEpoch(UserSlot storage slot, uint256 amount) private returns (uint256 requestId) {
        if (slot.pendingAmount != 0 && slot.epochId != currentEpochId) {
            revert PendingRequestUnfulfilled();
        }
        requestId = currentEpochId;
        slot.epochId = SafeCast.toUint64(requestId);
        slot.pendingAmount = SafeCast.toUint128(uint256(slot.pendingAmount) + amount);
    }

    // ---------------------------------------------------------------------
    // Cancellation — synchronous, pre-cut-off only (D7)
    // ---------------------------------------------------------------------

    /// @notice Cancel the full pending deposit of `controller` while its
    /// epoch is still OPEN; assets are refunded to `controller`.
    /// @dev Refund goes to the controller (not the original funds source):
    /// per spec the controller owns the request — the `owner` of the funds
    /// is not recorded. Callable by the controller or its operator.
    /// Cancellation is out of ERC-7540's scope; this synchronous pre-cut-off
    /// form is a documented divergence (see docs/contracts-tour.md).
    function cancelDepositRequest(address controller) external nonReentrant returns (uint256 assets) {
        _requireControllerOrOperator(controller);
        _rollDeposit(controller); // a fulfilled pending is claimable, not cancelable

        UserSlot memory slot = depositSlot[controller];
        if (slot.pendingAmount == 0) revert NoPendingRequest();
        if (slot.epochId != currentEpochId) revert RequestNotCancelable();

        assets = slot.pendingAmount;
        epochs[slot.epochId].totalDepositAssets -= assets;
        delete depositSlot[controller];

        escrow.transferTo(IERC20(asset()), controller, assets);
        emit DepositRequestCanceled(controller, slot.epochId, assets);
    }

    /// @notice Cancel the full pending redemption of `controller` while its
    /// epoch is still OPEN; shares are returned to `controller`.
    function cancelRedeemRequest(address controller) external nonReentrant returns (uint256 shares) {
        _requireControllerOrOperator(controller);
        _rollRedeem(controller);

        UserSlot memory slot = redeemSlot[controller];
        if (slot.pendingAmount == 0) revert NoPendingRequest();
        if (slot.epochId != currentEpochId) revert RequestNotCancelable();

        shares = slot.pendingAmount;
        epochs[slot.epochId].totalRedeemShares -= shares;
        delete redeemSlot[controller];

        escrow.transferTo(IERC20(address(this)), controller, shares);
        emit RedeemRequestCanceled(controller, slot.epochId, shares);
    }

    // ---------------------------------------------------------------------
    // Epoch machine — manager only (D5, D10)
    // ---------------------------------------------------------------------

    /// @notice Cut-off: the OPEN epoch's orders become binding, the next
    /// epoch opens immediately for new requests.
    /// @dev Reverts until the previous epoch is fulfilled, so at most one
    /// epoch awaits settlement at any time (I9). Closing an empty epoch is
    /// allowed — the manager may turn the cycle on a quiet day.
    function closeEpoch() external onlyRole(MANAGER_ROLE) returns (uint256 closedEpochId) {
        closedEpochId = currentEpochId;
        if (closedEpochId > 1 && epochs[closedEpochId - 1].fulfilledAt == 0) {
            revert PreviousEpochNotFulfilled();
        }
        Epoch storage epoch = epochs[closedEpochId];
        epoch.cutoffAt = SafeCast.toUint64(block.timestamp);
        currentEpochId = closedEpochId + 1;
        emit EpochClosed(closedEpochId, epoch.totalDepositAssets, epoch.totalRedeemShares);
    }

    /// @notice Settle the CLOSED epoch: one NAV, both sides, O(1) whatever
    /// the number of requests (D4/D6). Forward pricing: this is the first
    /// moment the epoch's execution price exists.
    /// @dev Exact operation order per docs/contracts-tour.md — the
    /// price snapshot PRECEDES any movement of epoch funds, which is what
    /// makes it honest:
    ///   1. strike: both batch conversions read the same pre-settlement
    ///      state. totalAssets() excludes escrowed pending cash (D9), while
    ///      totalSupply() still includes escrowed pending-redeem shares
    ///      (economically outstanding until burned below).
    ///   2. size the batch with OZ's own floor math (D1).
    ///   3. settle: mint→burn→pull→push. The final push reverts if vault
    ///      cash cannot cover `assetsSetAside` after netting the incoming
    ///      deposit cash — by design: the manager must `divest` first, like
    ///      a real fund selling T-Bills to fund redemptions.
    ///   4. record the batch results — the immutable pro-rata basis every
    ///      later per-user roll prices against (I1/I2).
    function fulfillEpoch() external nonReentrant onlyRole(MANAGER_ROLE) returns (uint256 epochId) {
        epochId = currentEpochId - 1; // the only possibly-CLOSED epoch
        Epoch storage epoch = epochs[epochId];
        if (epoch.cutoffAt == 0 || epoch.fulfilledAt != 0) revert NoEpochToFulfill();

        uint256 depositAssets = epoch.totalDepositAssets;
        uint256 redeemShares = epoch.totalRedeemShares;

        // 1–2. Strike the NAV once and size both sides on it (floor).
        uint256 sharesMinted = convertToShares(depositAssets);
        uint256 assetsSetAside = convertToAssets(redeemShares);
        uint256 navPerShare = convertToAssets(10 ** decimals());

        // 3. Settle. Only place in the code that mints or burns shares (I5).
        _mint(address(escrow), sharesMinted); // depositors' claimable shares
        _burn(address(escrow), redeemShares); // pending redeem shares retire
        escrow.transferTo(IERC20(asset()), address(this), depositAssets); // subscription cash joins the fund
        IERC20(asset()).safeTransfer(address(escrow), assetsSetAside); // redemption payout leaves it

        // 4. Record & advance.
        epoch.sharesMinted = sharesMinted;
        epoch.assetsSetAside = assetsSetAside;
        epoch.fulfilledAt = SafeCast.toUint64(block.timestamp);
        emit EpochFulfilled(epochId, depositAssets, redeemShares, sharesMinted, assetsSetAside, navPerShare);
    }

    // ---------------------------------------------------------------------
    // Portfolio management — manager only (D3)
    // ---------------------------------------------------------------------

    /// @notice Invest idle cash into T-Bills at the oracle price.
    function invest(uint256 assets) external nonReentrant onlyRole(MANAGER_ROLE) returns (uint256 tbillOut) {
        // NAV-neutral up to the primary market's floor rounding (≤1 unit of
        // dust borne by the fund) — the position swaps cash for equal value.
        IERC20(asset()).forceApprove(address(tbill), assets);
        tbillOut = tbill.subscribe(assets);
        emit Invested(assets, tbillOut);
    }

    /// @notice Sell T-Bills back at the oracle price (principal + accrued
    /// interest) — typically to fund a redemption-heavy epoch before
    /// fulfilling it.
    function divest(uint256 tbillAmount) external nonReentrant onlyRole(MANAGER_ROLE) returns (uint256 assetsOut) {
        assetsOut = tbill.redeem(tbillAmount);
        emit Divested(tbillAmount, assetsOut);
    }

    // ---------------------------------------------------------------------
    // Claims — the ERC-4626 entry points, reinterpreted per ERC-7540
    // ---------------------------------------------------------------------
    // No pricing happens here: assets moved at request time, shares were
    // minted at fulfillment. Claims only release escrowed value against the
    // controller's ledger, pro-rata when partial. Rounding: outputs floor,
    // inputs-consumed ceil (T3 — always in the vault's favor), with an
    // exactness shortcut on full claims so nothing is ever stranded.

    /// @notice Claim shares against `assets` of msg.sender's fulfilled
    /// deposits. NOT a synchronous deposit — funds moved at request time.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _requireControllerOrOperator(controller);
        _rollDeposit(controller);

        ClaimBalance storage claim = claimableDeposit[controller];
        if (assets == 0) revert ZeroAmount();
        if (assets > claim.assets) revert ExceedsClaimable(assets, claim.assets);
        shares = assets == claim.assets ? claim.shares : Math.mulDiv(assets, claim.shares, claim.assets);
        claim.assets -= assets;
        claim.shares -= shares;

        escrow.transferTo(IERC20(address(this)), receiver, shares);
        // Spec: "the first parameter MUST be the controller, and the second
        // parameter MUST be the receiver" (an operator may be msg.sender).
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @notice Claim `shares` of msg.sender's fulfilled deposits.
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        return mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _requireControllerOrOperator(controller);
        _rollDeposit(controller);

        ClaimBalance storage claim = claimableDeposit[controller];
        if (shares == 0) revert ZeroAmount();
        if (shares > claim.shares) revert ExceedsClaimable(shares, claim.shares);
        assets =
            shares == claim.shares ? claim.assets : Math.mulDiv(shares, claim.assets, claim.shares, Math.Rounding.Ceil);
        claim.assets -= assets;
        claim.shares -= shares;

        escrow.transferTo(IERC20(address(this)), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @notice Claim `assets` of the controller's fulfilled redemptions.
    /// @dev Third parameter is the CONTROLLER, not the share owner (spec
    /// renames it): claims need controller/operator standing — the ERC-4626
    /// share-allowance path does NOT apply, shares were escrowed at request.
    function withdraw(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _requireControllerOrOperator(controller);
        _rollRedeem(controller);

        ClaimBalance storage claim = claimableRedeem[controller];
        if (assets == 0) revert ZeroAmount();
        if (assets > claim.assets) revert ExceedsClaimable(assets, claim.assets);
        shares =
            assets == claim.assets ? claim.shares : Math.mulDiv(assets, claim.shares, claim.assets, Math.Rounding.Ceil);
        claim.assets -= assets;
        claim.shares -= shares;

        escrow.transferTo(IERC20(asset()), receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @notice Claim the payout of `shares` of the controller's fulfilled
    /// redemptions. Same controller semantics as {withdraw}.
    function redeem(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _requireControllerOrOperator(controller);
        _rollRedeem(controller);

        ClaimBalance storage claim = claimableRedeem[controller];
        if (shares == 0) revert ZeroAmount();
        if (shares > claim.shares) revert ExceedsClaimable(shares, claim.shares);
        assets = shares == claim.shares ? claim.assets : Math.mulDiv(shares, claim.assets, claim.shares);
        claim.assets -= assets;
        claim.shares -= shares;

        escrow.transferTo(IERC20(asset()), receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    // ---------------------------------------------------------------------
    // max* — the controller's claimable amounts (spec) ; preview* — revert
    // ---------------------------------------------------------------------

    /// @notice Max `assets` claimable via {deposit} by `controller`.
    function maxDeposit(address controller) public view override returns (uint256 assets) {
        (assets,) = _depositClaimBalance(controller);
    }

    /// @notice Max `shares` claimable via {mint} by `controller`.
    function maxMint(address controller) public view override returns (uint256 shares) {
        (, shares) = _depositClaimBalance(controller);
    }

    /// @notice Max `assets` claimable via {withdraw} by `controller`.
    function maxWithdraw(address controller) public view override returns (uint256 assets) {
        (assets,) = _redeemClaimBalance(controller);
    }

    /// @notice Max `shares` claimable via {redeem} by `controller`.
    function maxRedeem(address controller) public view override returns (uint256 shares) {
        (, shares) = _redeemClaimBalance(controller);
    }

    /// @notice Reverts (spec): the execution price of an async request does
    /// not exist before its epoch is fulfilled — pretending otherwise is the
    /// dilution bug forward pricing exists to prevent.
    function previewDeposit(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @notice Reverts (spec) — see {previewDeposit}.
    function previewMint(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @notice Reverts (spec) — see {previewDeposit}.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @notice Reverts (spec) — see {previewDeposit}.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    // ---------------------------------------------------------------------
    // ERC-7540 request views
    // ---------------------------------------------------------------------
    // Views simulate the lazy roll (they cannot write): a fulfilled slot
    // reads as claimable, never as pending, so on-chain readers and the
    // frontend see settled state the moment fulfillEpoch() lands.

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 pendingAssets)
    {
        UserSlot memory slot = depositSlot[controller];
        if (slot.pendingAmount != 0 && slot.epochId == requestId && epochs[slot.epochId].fulfilledAt == 0) {
            pendingAssets = slot.pendingAmount;
        }
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 pendingShares)
    {
        UserSlot memory slot = redeemSlot[controller];
        if (slot.pendingAmount != 0 && slot.epochId == requestId && epochs[slot.epochId].fulfilledAt == 0) {
            pendingShares = slot.pendingAmount;
        }
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev `requestId` is ignored: once fulfilled, claims are fungible —
    /// the single-slot lazy roll (D4) aggregates entitlements from different
    /// epochs into one ledger, so per-epoch attribution no longer exists.
    /// This is the fungible-request model the spec explicitly allows;
    /// `maxDeposit`/`maxMint` are the canonical claimable amounts.
    function claimableDepositRequest(uint256, address controller)
        external
        view
        override
        returns (uint256 claimableAssets)
    {
        (claimableAssets,) = _depositClaimBalance(controller);
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev `requestId` ignored — same fungibility rationale as
    /// {claimableDepositRequest}.
    function claimableRedeemRequest(uint256, address controller)
        external
        view
        override
        returns (uint256 claimableShares)
    {
        (, claimableShares) = _redeemClaimBalance(controller);
    }

    // ---------------------------------------------------------------------
    // ERC-7540 operators, ERC-7575, ERC-165
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external override returns (bool success) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @inheritdoc IERC7575
    function share() external view override returns (address shareTokenAddress) {
        return address(this); // single-token vault: the share IS the vault
    }

    /// @dev The four ids are the EIP-mandated constants, hardcoded on
    /// purpose: computing type(X).interfaceId over our (partial) local
    /// interfaces would not reproduce them (e.g. IERC7575 here only declares
    /// `share()`, while 0x2f0a18c5 covers the full 7575 vault surface).
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return interfaceId == 0xe3bc4e65 // ERC-7540 operator methods
            || interfaceId == 0x2f0a18c5 // ERC-7575 vault
            || interfaceId == 0xce3bbe50 // ERC-7540 asynchronous deposit
            || interfaceId == 0x620ee8e4 // ERC-7540 asynchronous redemption
            || super.supportsInterface(interfaceId); // ERC-165, AccessControl
    }

    // ---------------------------------------------------------------------
    // Internal — lazy settlement (pending → claimable roll)
    // ---------------------------------------------------------------------
    // Entitlements are pro-rata AGAINST THE RECORDED BATCH RESULT, not a
    // stored price: userShares = userAssets × sharesMinted ÷ totalDeposit
    // (floor). Σ user claims ≤ batch result holds term by term (I2), and no
    // rounding error compounds through a price. Dust stays in escrow,
    // unclaimable, < 1 wei per user per epoch.

    /// @dev Materialize `controller`'s deposit entitlement if its slot's
    /// epoch has been fulfilled; no-op otherwise. Frees the slot atomically
    /// with crediting the ledger (I7 — no double-claim window).
    function _rollDeposit(address controller) private {
        UserSlot memory slot = depositSlot[controller];
        if (slot.pendingAmount == 0) return;
        Epoch storage epoch = epochs[slot.epochId];
        if (epoch.fulfilledAt == 0) return;

        uint256 entitledShares = Math.mulDiv(slot.pendingAmount, epoch.sharesMinted, epoch.totalDepositAssets);
        ClaimBalance storage claim = claimableDeposit[controller];
        claim.assets += slot.pendingAmount;
        claim.shares += entitledShares;
        delete depositSlot[controller];
        emit DepositClaimable(controller, slot.epochId, slot.pendingAmount, entitledShares);
    }

    /// @dev Redeem-side twin of {_rollDeposit}.
    function _rollRedeem(address controller) private {
        UserSlot memory slot = redeemSlot[controller];
        if (slot.pendingAmount == 0) return;
        Epoch storage epoch = epochs[slot.epochId];
        if (epoch.fulfilledAt == 0) return;

        uint256 entitledAssets = Math.mulDiv(slot.pendingAmount, epoch.assetsSetAside, epoch.totalRedeemShares);
        ClaimBalance storage claim = claimableRedeem[controller];
        claim.shares += slot.pendingAmount;
        claim.assets += entitledAssets;
        delete redeemSlot[controller];
        emit RedeemClaimable(controller, slot.epochId, slot.pendingAmount, entitledAssets);
    }

    /// @dev View-side simulation of {_rollDeposit}: stored ledger plus the
    /// as-if-rolled slot. Uses the same math, so a view never disagrees with
    /// the state a touchpoint would produce.
    function _depositClaimBalance(address controller) private view returns (uint256 assets, uint256 shares) {
        ClaimBalance memory claim = claimableDeposit[controller];
        (assets, shares) = (claim.assets, claim.shares);
        UserSlot memory slot = depositSlot[controller];
        if (slot.pendingAmount != 0) {
            Epoch storage epoch = epochs[slot.epochId];
            if (epoch.fulfilledAt != 0) {
                assets += slot.pendingAmount;
                shares += Math.mulDiv(slot.pendingAmount, epoch.sharesMinted, epoch.totalDepositAssets);
            }
        }
    }

    /// @dev View-side simulation of {_rollRedeem}.
    function _redeemClaimBalance(address controller) private view returns (uint256 assets, uint256 shares) {
        ClaimBalance memory claim = claimableRedeem[controller];
        (assets, shares) = (claim.assets, claim.shares);
        UserSlot memory slot = redeemSlot[controller];
        if (slot.pendingAmount != 0) {
            Epoch storage epoch = epochs[slot.epochId];
            if (epoch.fulfilledAt != 0) {
                shares += slot.pendingAmount;
                assets += Math.mulDiv(slot.pendingAmount, epoch.assetsSetAside, epoch.totalRedeemShares);
            }
        }
    }

    /// @dev Spec caller rule shared by claims and cancels: the controller
    /// owns the request; only it or its approved operators act on it.
    function _requireControllerOrOperator(address controller) private view {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) revert NotAuthorized();
    }
}
